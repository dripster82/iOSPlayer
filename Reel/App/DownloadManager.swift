import Foundation
import SwiftUI
import UIKit
import MediaCore
import MediaSources
import Library

/// Copies of episodes and films kept on the device for watching away from the NAS. One download at
/// a time, in order; the file goes to Documents/Downloads/<item>.<ext>, excluded from iCloud backup,
/// and the player prefers it over the network copy whenever it exists.
@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable { case queued, downloading, failed(String) }
    struct Entry: Identifiable, Equatable {
        var itemKey: String
        var title: String
        var subtitle: String?
        var fileName: String
        var bytes: Int64 = 0
        var total: Int64 = 0
        var state: State = .queued
        var id: String { itemKey }
        var progress: Double { total > 0 ? Double(bytes) / Double(total) : 0 }
    }

    /// Queued, in flight, or failed; done entries leave the list and join `downloaded`.
    @Published private(set) var active: [Entry] = []
    /// Item keys with a finished file on disk.
    @Published private(set) var downloaded: Set<String> = []
    @Published private(set) var totalBytes: Int64 = 0

    private let library: LibraryStore
    private var worker: Task<Void, Never>?
    /// Read from the download's progress callback off the main actor, hence the lock.
    private let cancelled = CancelBox()
    private var lastProgressPublish = Date.distantPast
    final class CancelBox: @unchecked Sendable {
        private let lock = NSLock(); private var keys: Set<String> = []
        func insert(_ k: String) { lock.lock(); keys.insert(k); lock.unlock() }
        func remove(_ k: String) { lock.lock(); keys.remove(k); lock.unlock() }
        func contains(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return keys.contains(k) }
    }

    init(library: LibraryStore) {
        self.library = library
        refresh()
    }

    // MARK: - Files

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static func safeName(_ itemKey: String) -> String {
        String((itemKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemKey).prefix(180))
    }

    /// The finished file for an item, if it has one. Static so the player can ask without the manager.
    nonisolated static func localURL(for itemKey: String) -> URL? {
        let prefix = safeName(itemKey) + "."
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(prefix) && !$0.lastPathComponent.hasSuffix(".part") }
    }

    func isDownloaded(_ itemKey: String) -> Bool { downloaded.contains(itemKey) }
    func entry(for itemKey: String) -> Entry? { active.first { $0.itemKey == itemKey } }

    /// Sizes and keys from disk. Cheap: a few dozen files at most.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var keys = Set<String>(); var total: Int64 = 0
        for f in files where !f.lastPathComponent.hasSuffix(".part") {
            let stem = f.deletingPathExtension().lastPathComponent
            if let key = stem.removingPercentEncoding { keys.insert(key) }
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        downloaded = keys; totalBytes = total
    }

    /// Every finished download with its size, newest first, for the Downloads screen.
    func finished() -> [(itemKey: String, url: URL, bytes: Int64, title: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return files.filter { !$0.lastPathComponent.hasSuffix(".part") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .map { url in
                let key = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
                let item = library.item(key)
                let title = item.map { $0.kind == .episode ? "\($0.show?.title ?? "") · \($0.episodeCode ?? "") \($0.title)" : $0.title } ?? url.lastPathComponent
                return (key, url, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), title)
            }
    }

    // MARK: - Queue

    func enqueue(_ item: MediaItem) {
        guard !downloaded.contains(item.itemKey), entry(for: item.itemKey) == nil, let file = library.preferredFile(item) else { return }
        let subtitle = item.kind == .episode ? [item.show?.title, item.episodeCode].compactMap { $0 }.joined(separator: " · ") : item.year.map(String.init)
        active.append(Entry(itemKey: item.itemKey, title: item.title, subtitle: subtitle, fileName: file.fileName, total: file.size))
        cancelled.remove(item.itemKey)
        Diagnostics.log("downloads", "queued \(file.fileName)")
        startWorker()
    }

    func enqueue(season: Int, of show: MediaItem) {
        for ep in show.episodes.filter({ $0.seasonNumber == season }).sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }) { enqueue(ep) }
    }

    func cancel(_ itemKey: String) {
        cancelled.insert(itemKey)
        active.removeAll { $0.itemKey == itemKey && $0.state != .downloading }
    }

    func retry(_ itemKey: String) {
        guard let i = active.firstIndex(where: { $0.itemKey == itemKey }) else { return }
        active[i].state = .queued; active[i].bytes = 0
        startWorker()
    }

    func remove(_ itemKey: String) {
        cancel(itemKey)
        if let url = Self.localURL(for: itemKey) { try? FileManager.default.removeItem(at: url) }
        Diagnostics.log("downloads", "removed \(itemKey.prefix(60))")
        refresh()
    }

    func removeAll() {
        for key in downloaded { if let url = Self.localURL(for: key) { try? FileManager.default.removeItem(at: url) } }
        active.removeAll { $0.state != .downloading }
        refresh()
    }

    private func publish(key: String, bytes: Int64, total: Int64) {
        guard let i = active.firstIndex(where: { $0.itemKey == key }) else { return }
        guard Date().timeIntervalSince(lastProgressPublish) > 0.5 || bytes == total else { return }
        lastProgressPublish = Date()
        active[i].bytes = bytes
        if total > 0 { active[i].total = total }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.active.first(where: { $0.state == .queued }) {
                await self.run(next)
            }
            self?.worker = nil
        }
    }

    private func run(_ entry: Entry) async {
        guard let i = active.firstIndex(where: { $0.itemKey == entry.itemKey }) else { return }
        active[i].state = .downloading
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel download")
        defer { UIApplication.shared.endBackgroundTask(assertion) }
        do {
            guard let item = library.item(entry.itemKey), let file = library.preferredFile(item), let record = file.source else { throw SourceError.notFound(entry.fileName) }
            let source = SourceFactory.make(record.config)
            try await source.connect(credentials: CredentialStore.shared.load(for: record.id))
            let ext = (file.fileName as NSString).pathExtension
            let final = Self.directory.appendingPathComponent(Self.safeName(entry.itemKey) + "." + (ext.isEmpty ? "mkv" : ext))
            let part = final.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            let key = entry.itemKey
            let started = Date()
            let cancelled = self.cancelled
            try await source.download(file.relativePath, to: part) { [weak self] bytes, total in
                Task { @MainActor in self?.publish(key: key, bytes: bytes, total: total) }
                return !cancelled.contains(key)
            }
            await source.disconnect()
            if cancelled.contains(key) { try? FileManager.default.removeItem(at: part); throw CancellationError() }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = final; try? url.setResourceValues(values)
            active.removeAll { $0.itemKey == key }
            refresh()
            Diagnostics.log("downloads", "finished \(file.fileName) in \(Int(Date().timeIntervalSince(started)))s")
        } catch is CancellationError {
            active.removeAll { $0.itemKey == entry.itemKey }
            Diagnostics.log("downloads", "cancelled \(entry.fileName)")
        } catch {
            if let i = active.firstIndex(where: { $0.itemKey == entry.itemKey }) { active[i].state = .failed(error.localizedDescription) }
            Diagnostics.log("downloads", "\(entry.fileName) failed: \(error.localizedDescription)")
        }
    }
}
