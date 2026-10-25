#if canImport(SwiftData)
import Foundation
import SwiftData
import MediaCore
import MediaSources
import Metadata
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Main-thread façade over the model container: queries the views need, plus the write
/// operations that must also mark rows for sync. Heavy work (scanning) runs on `Scanner`.
@MainActor
public final class LibraryStore: ObservableObject {
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public let deviceID: String

    @Published public private(set) var scanProgress: [UUID: ScanProgress] = [:]
    @Published public var lastError: String?
    /// Set by the app once the sync engine exists. Every write that marks rows `pendingSync` calls `changed`.
    public var syncHooks: SyncHooks?
    private func notifySync() { invalidateCaches(); syncHooks?.changed() }

    // Per-render lookups (poster cards, filters) read these instead of hitting SwiftData per item.
    // Built lazily from one fetch each; dropped on every write and whenever sync applies changes.
    private var watchCache: [String: WatchState]?
    private var favouriteCache: Set<String>?
    public func invalidateCaches() { watchCache = nil; favouriteCache = nil; groupIndexCache = nil }
    private var groupIndexCache: GroupIndex?
    private var scanTasks: [UUID: Task<Void, Never>] = [:]

    public init(container: ModelContainer) {
        self.container = container
        let key = "reel.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { deviceID = id }
        else { let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: key); deviceID = id }
    }

    // MARK: - Sources

    public func sources() -> [SourceRecord] {
        (try? context.fetch(FetchDescriptor<SourceRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    @discardableResult
    public func addSource(_ config: SourceConfig, credentials: Credentials?, folderRules: [(String, FolderTag)]) throws -> SourceRecord {
        var config = config
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        let record = SourceRecord(config: config)
        for (path, tag) in folderRules {
            let rule = FolderRule(folderPath: path, tag: tag, includeInScan: tag != .excluded)
            rule.source = record
            record.folderRules.append(rule)
        }
        record.pendingSync = true; record.updatedAt = Date()
        context.insert(record)
        try context.save()
        if let credentials { try CredentialStore.shared.save(credentials, for: config.id) }
        notifySync()
        return record
    }

    public func removeSource(_ record: SourceRecord) throws {
        scanTasks[record.id]?.cancel()
        CredentialStore.shared.remove(for: record.id)
        let sourceID = record.id
        var deleted = [SyncKeys.source(sourceID)]
        var touched: [MediaItem] = []
        for f in record.files {
            deleted.append(SyncKeys.file(sourceID: sourceID, relativePath: f.relativePath))
            if let item = f.item { touched.append(item) }
        }
        context.delete(record)   // cascades to files and folder rules
        try context.save()
        // Items left with no files (from any source) go too, including shows emptied of episodes.
        for item in touched where !item.isDeleted && item.files.isEmpty {
            deleted.append(SyncKeys.item(item.itemKey))
            let show = item.show
            context.delete(item)
            if let show, show.episodes.allSatisfy(\.isDeleted) { deleted.append(SyncKeys.item(show.itemKey)); context.delete(show) }
        }
        try context.save()
        syncHooks?.deleted(deleted)
    }

    public func setTag(_ tag: FolderTag?, folder: String, on record: SourceRecord) throws {
        if let existing = record.folderRules.first(where: { $0.folderPath == folder }) {
            if let tag { existing.tagRaw = tag.rawValue; existing.includeInScan = tag != .excluded } else { context.delete(existing) }
        } else if let tag {
            let rule = FolderRule(folderPath: folder, tag: tag, includeInScan: tag != .excluded)
            rule.source = record
            record.folderRules.append(rule)
        }
        try context.save()
        record.pendingSync = true; record.updatedAt = Date()
        try context.save()
        notifySync()
        // Excluding a folder should empty it from the library now, not just skip it on the next scan.
        if tag == .excluded { purgeInBackground(folder, sourceID: record.id) }
    }

    /// Drops a folder from a source: its rule now, then every file under it and any item left with no
    /// files in the background. The next scan only brings the folder back if it still sits inside an
    /// included root.
    public func removeFolder(_ folder: String, from record: SourceRecord) throws {
        if let existing = record.folderRules.first(where: { $0.folderPath == folder }) { context.delete(existing) }
        record.pendingSync = true; record.updatedAt = Date()
        try context.save()
        notifySync()
        purgeInBackground(folder, sourceID: record.id)
    }

    private var lastProgressPublish: [UUID: Date] = [:]

    /// Every publish re-renders every view observing the store, so progress is limited to once a second
    /// per source, except for phase changes, which always go through.
    private func publishProgress(_ p: ScanProgress) {
        let now = Date()
        let phaseChanged = scanProgress[p.sourceID]?.phase != p.phase
        guard phaseChanged || now.timeIntervalSince(lastProgressPublish[p.sourceID] ?? .distantPast) >= 1 else { return }
        lastProgressPublish[p.sourceID] = now
        scanProgress[p.sourceID] = p
    }

    /// Folders being emptied right now, so the UI can show it.
    @Published public private(set) var purging: Set<String> = []

    private func purgeInBackground(_ folder: String, sourceID: UUID) {
        purging.insert(folder)
        let maintenance = LibraryMaintenance(modelContainer: container)
        Task { [weak self] in
            var deleted: [String] = []
            do { deleted = try await maintenance.purgeFiles(under: folder, sourceID: sourceID) }
            catch { await MainActor.run { [weak self] in self?.lastError = error.localizedDescription } }
            await MainActor.run { [weak self] in
                self?.purging.remove(folder)
                self?.objectWillChange.send()
                if !deleted.isEmpty { self?.syncHooks?.deleted(deleted) }
            }
        }
    }

    public func isScanning(_ id: UUID) -> Bool { scanTasks[id] != nil }
    public var isScanning: Bool { !scanTasks.isEmpty }

    /// Suspends until every running scan has finished. Used by the background processing task.
    public func waitForScans() async {
        for task in Array(scanTasks.values) { await task.value }
    }

    /// Stops running scans. Progress so far is saved every few files, so a later scan resumes cheaply.
    public func cancelScans() {
        scanTasks.values.forEach { $0.cancel() }
    }

    public func scan(_ record: SourceRecord, tmdb: TMDbClient?) { scan(record, providers: MetadataProviders(tmdb: tmdb)) }
    public func scanAll(tmdb: TMDbClient?) { scanAll(providers: MetadataProviders(tmdb: tmdb)) }

    public func scan(_ record: SourceRecord, providers: MetadataProviders) {
        guard scanTasks[record.id] == nil else { return }
        let id = record.id
        let creds = CredentialStore.shared.load(for: id)
        let scanner = LibraryScanner(modelContainer: container)
        // Keep running for a while after the user leaves the app; iOS grants a few minutes.
        let assertion = BackgroundAssertion(name: "Reel scan \(record.name)")
        Diagnostics.log("scan", "start \(record.name)")
        scanTasks[id] = Task { [weak self] in
            do {
                let dropped = try await scanner.scan(sourceID: id, credentials: creds, providers: providers) { p in
                    Task { @MainActor [weak self] in self?.publishProgress(p) }
                }
                if !dropped.isEmpty { await MainActor.run { [weak self] in self?.syncHooks?.deleted(dropped) } }
            } catch is CancellationError {
                // Expected when the background task expires or the user stops a scan.
            } catch {
                Diagnostics.log("scan", "\(record.name) failed: \(error.localizedDescription)")
                await MainActor.run { [weak self] in self?.lastError = error.localizedDescription }
            }
            Diagnostics.log("scan", "finished \(record.name)")
            await MainActor.run { [weak self] in
                self?.scanTasks[id] = nil
                self?.objectWillChange.send()
                assertion.end()
                self?.notifySync()
            }
        }
    }

    public func scanAll(providers: MetadataProviders) { sources().forEach { scan($0, providers: providers) } }

    /// Rescans just the folder(s) this title's files live in: new episodes, a replaced file, a deleted
    /// one. Seconds instead of the minutes a whole source takes. Waits for the result.
    public func rescan(folderOf item: MediaItem, providers: MetadataProviders) async {
        let files = item.kind == .show ? item.episodes.flatMap(\.files) : item.files
        var folders: [UUID: String] = [:]
        for f in files {
            guard let s = f.source else { continue }
            let dir = (f.relativePath as NSString).deletingLastPathComponent
            folders[s.id] = folders[s.id].map { Self.commonFolder($0, dir) } ?? dir
        }
        for (id, folder) in folders {
            guard scanTasks[id] == nil else { continue }   // a full scan of that source is already running
            let scanner = LibraryScanner(modelContainer: container)
            Diagnostics.log("scan", "rescan folder \(folder.isEmpty ? "/" : folder)")
            do {
                let dropped = try await scanner.scan(sourceID: id, credentials: CredentialStore.shared.load(for: id), providers: providers, scope: folder) { p in
                    Task { @MainActor [weak self] in self?.publishProgress(p) }
                }
                if !dropped.isEmpty { syncHooks?.deleted(dropped) }
            } catch {
                Diagnostics.log("scan", "rescan of \(folder) failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
        }
        objectWillChange.send()
        notifySync()
    }

    /// "A/B/Season 1" and "A/B/Season 2" share "A/B".
    static func commonFolder(_ a: String, _ b: String) -> String {
        var out: [Substring] = []
        for (x, y) in zip(a.split(separator: "/"), b.split(separator: "/")) {
            if x == y { out.append(x) } else { break }
        }
        return out.joined(separator: "/")
    }

    // MARK: - Items

    public func items(kind: MediaKind, includeHidden: Bool = false) -> [MediaItem] {
        let raw = kind.rawValue
        let d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.kindRaw == raw && (includeHidden || !$0.hidden) }, sortBy: [SortDescriptor(\.sortTitle)])
        return (try? context.fetch(d)) ?? []
    }

    public func item(_ key: String) -> MediaItem? {
        var d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key }); d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func search(_ query: String) -> [MediaItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.title.localizedStandardContains(q) && !$0.hidden }, sortBy: [SortDescriptor(\.sortTitle)])
        return (try? context.fetch(d)) ?? []
    }

    /// Files the classifier accepted that still have no TMDb item: scanned without a key, or the matcher failed.
    public func unmatchedFileCount() -> Int {
        let d = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.item == nil && !$0.ignored && !$0.reviewed && ($0.classificationRaw == "episode" || $0.classificationRaw == "film") })
        return (try? context.fetchCount(d)) ?? 0
    }

    /// The last matcher error from any finished scan, if the matcher gave up on files.
    public var lastMatchError: String? {
        scanProgress.values.first { $0.phase == .done && $0.skipped > 0 && $0.lastError != nil }?.lastError
    }

    public func filesNeedingReview() -> [MediaFile] {
        let d = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.classificationRaw == "review" && !$0.reviewed && !$0.ignored }, sortBy: [SortDescriptor(\.relativePath)])
        return (try? context.fetch(d)) ?? []
    }

    public func allGenres(kind: MediaKind) -> [String] { Array(Set(items(kind: kind).flatMap(\.genres))).sorted() }

    public func hide(_ item: MediaItem) throws {
        item.hidden = true
        item.pendingSync = true; item.updatedAt = Date()
        for f in item.files { let o = override(for: f); o.hidden = true; o.updatedAt = Date(); o.pendingSync = true }
        try context.save()
        notifySync()
    }

    // MARK: - Review and fix match

    public func resolveReview(_ file: MediaFile, as kind: MediaKind?, tmdbID: Int?, anidbID: Int? = nil, tmdb: TMDbClient, providers: MetadataProviders? = nil) async throws {
        let o = override(for: file)
        o.forcedKindRaw = kind?.rawValue
        o.forcedTMDbID = tmdbID
        o.forcedAniDBID = anidbID
        o.updatedAt = Date(); o.pendingSync = true
        file.reviewed = true
        file.classificationRaw = kind == .episode ? "episode" : "film"
        file.pendingSync = true; file.updatedAt = Date()
        try context.save()
        let matcher = providers.map { Matcher(context: context, tmdb: tmdb, providers: $0) } ?? Matcher(context: context, tmdb: tmdb)
        let outcome = await matcher.match(file)
        try context.save()
        Diagnostics.log("library", "review: \(file.fileName.prefix(50)) set to \(kind?.rawValue ?? "auto")\(tmdbID.map { " tmdb \($0)" } ?? "") → \(outcome)\(file.item.map { ", item \($0.itemKey)" } ?? ", no item")")
        notifySync()
    }

    /// Same decision for a whole folder of review items: one TMDb lookup per file, one save, one sync.
    public func resolveReview(_ files: [MediaFile], as kind: MediaKind?, tmdbID: Int?, anidbID: Int? = nil, tmdb: TMDbClient, providers: MetadataProviders? = nil) async throws {
        let matcher = providers.map { Matcher(context: context, tmdb: tmdb, providers: $0) } ?? Matcher(context: context, tmdb: tmdb)
        for file in files {
            let o = override(for: file)
            o.forcedKindRaw = kind?.rawValue
            o.forcedTMDbID = tmdbID
            o.forcedAniDBID = anidbID
            o.updatedAt = Date(); o.pendingSync = true
            file.reviewed = true
            file.classificationRaw = kind == .episode ? "episode" : "film"
            file.pendingSync = true; file.updatedAt = Date()
        }
        try context.save()
        for file in files { _ = await matcher.match(file) }
        try context.save()
        Diagnostics.log("library", "review: \(files.count) files set to \(kind?.rawValue ?? "auto")\(tmdbID.map { " tmdb \($0)" } ?? "")")
        notifySync()
    }

    public func ignoreFiles(_ files: [MediaFile]) throws {
        for file in files {
            file.ignored = true
            file.pendingSync = true; file.updatedAt = Date()
            let o = override(for: file); o.hidden = true; o.updatedAt = Date(); o.pendingSync = true
        }
        try context.save()
        notifySync()
    }

    public func ignoreFile(_ file: MediaFile) throws {
        file.ignored = true
        file.pendingSync = true; file.updatedAt = Date()
        let o = override(for: file); o.hidden = true; o.updatedAt = Date(); o.pendingSync = true
        try context.save()
        notifySync()
    }

    /// Re-points every file of an item at a different TMDb entry. Used by Fix Match.
    /// Old item key → the key of the title it was rematched to this launch, so an open page can follow.
    public private(set) var rematched: [String: String] = [:]

    /// Returns the key of the item the files now belong to. For a show, every episode's file moves.
    @discardableResult
    public func fixMatch(_ item: MediaItem, tmdbID: Int, kind: MediaKind, anidbID: Int? = nil, tmdb: TMDbClient, providers: MetadataProviders? = nil) async throws -> String? {
        try await fixMatch(item, files: item.kind == .show ? item.episodes.flatMap(\.files) : item.files, tmdbID: tmdbID, kind: kind, anidbID: anidbID, tmdb: tmdb, providers: providers)
    }

    /// Re-points just `files` (some of a show's episodes, or one episode's file) at `tmdbID`. `item` is
    /// the page the sheet was opened from; it is retired only if it ends up with nothing.
    @discardableResult
    public func fixMatch(_ item: MediaItem, files: [MediaFile], tmdbID: Int, kind: MediaKind, anidbID: Int? = nil, tmdb: TMDbClient, providers: MetadataProviders? = nil) async throws -> String? {
        var previous: [MediaItem] = []
        for f in files {
            if let p = f.item, !previous.contains(where: { $0 === p }) { previous.append(p) }
            let o = override(for: f)
            o.forcedTMDbID = tmdbID
            o.forcedKindRaw = kind.rawValue
            o.forcedAniDBID = anidbID
            o.updatedAt = Date(); o.pendingSync = true
            f.item = nil
        }
        try context.save()
        let matcher = providers.map { Matcher(context: context, tmdb: tmdb, providers: $0) } ?? Matcher(context: context, tmdb: tmdb)
        for f in files { _ = await matcher.match(f) }
        // Only now, with the new title in place, retire the old one. The page under the sheet redraws
        // on every save; flagging the orphan before its replacement existed left it with nothing to show.
        var deleted: [String] = []
        var orphans = previous.filter { $0.files.isEmpty && !$0.pendingDeletion }
        for p in previous {
            if let show = p.show, !orphans.contains(where: { $0 === show }), show.episodes.allSatisfy({ $0.files.isEmpty || $0.pendingDeletion }) { orphans.append(show) }
        }
        if item.kind == .show, !orphans.contains(where: { $0 === item }), item.episodes.allSatisfy({ $0.files.isEmpty || $0.pendingDeletion }) { orphans.append(item) }
        let itemRetired = orphans.contains { $0 === item } || (item.kind == .episode && orphans.contains { $0 === item.show })
        for o in orphans {
            // Not deleted here: the detail page under the Fix Match sheet still holds this object.
            deleted.append(SyncKeys.item(o.itemKey))
            o.pendingDeletion = true
            o.hidden = true
        }
        let target = files.first?.item.map { $0.kind == .episode ? ($0.show?.itemKey ?? $0.itemKey) : $0.itemKey }
        if let target, itemRetired {
            rematched[item.itemKey] = target
            if let show = item.show { rematched[show.itemKey] = target }
            // The user's collections follow the title to its new identity.
            for c in collections() where c.itemKeys.contains(item.itemKey) {
                c.itemKeys = c.itemKeys.map { $0 == item.itemKey ? target : $0 }
                c.updatedAt = Date(); c.pendingSync = true
            }
        }
        try context.save()
        if !deleted.isEmpty { syncHooks?.deleted(deleted) }
        notifySync()
        objectWillChange.send()
        Diagnostics.log("library", "fix match: \(item.title.prefix(40)) → tmdb \(tmdbID) (\(files.count) files) now \(target ?? "unmatched")")
        return target
    }

    /// Deletes the orphans Fix Match left behind. Called once at launch, before any page can hold one.
    public func purgePendingDeletions() {
        let d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.pendingDeletion })
        guard let orphans = try? context.fetch(d), !orphans.isEmpty else { return }
        for o in orphans where o.files.isEmpty { context.delete(o) }
        try? context.save()
        Diagnostics.log("library", "purged \(orphans.count) rematched orphans")
    }

    private func override(for file: MediaFile) -> ItemOverride {
        let key = ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: file.duration)
        var d = FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key }); d.fetchLimit = 1
        if let o = try? context.fetch(d).first { return o }
        let o = ItemOverride(fileKey: key)
        context.insert(o)
        return o
    }

    /// Films and shows in the library with this person in the cast (by name: cast lists are short).
    public func items(withCastMember name: String) -> [MediaItem] {
        (items(kind: .film) + items(kind: .show)).filter { $0.cast.contains(name) }.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    /// Library items by TMDb id, to mark which of a person's credits are owned.
    public func items(tmdbIDs: Set<Int>) -> [Int: MediaItem] {
        var out: [Int: MediaItem] = [:]
        for i in items(kind: .film) + items(kind: .show) where i.tmdbID.map(tmdbIDs.contains) == true { out[i.tmdbID!] = i }
        return out
    }

    /// What the player found in a file once it opened; shown on the film page and the Versions list.
    public func recordProbe(itemKey: String, fileID: UUID?, videoCodec: String?, audio: String?, subtitles: String?, duration: TimeInterval) {
        guard let item = item(itemKey) else { return }
        guard let file = fileID.flatMap({ id in item.files.first { $0.id == id } }) ?? preferredFile(item) else { return }
        var changed = false
        if let v = videoCodec, v != file.videoCodec { file.videoCodec = v; changed = true }
        if let a = audio, a != file.audioSummary { file.audioSummary = a; changed = true }
        if let s = subtitles, s != file.subtitleSummary { file.subtitleSummary = s; changed = true }
        if duration > 0, abs((file.duration ?? 0) - duration) > 1 { file.duration = duration; changed = true }
        if changed { file.pendingSync = true; file.updatedAt = Date(); try? context.save() }
    }

    /// What the player has learned about the files so far: codecs by count, 4K and HDR (from the file
    /// names) counts, and how many files have not been played yet, so nothing is known about them.
    /// Files are only probed when they play; a scan never opens them.
    public struct CodecSummary: Sendable {
        public var codecs: [(name: String, count: Int)] = []
        public var uhd = 0
        public var hdr = 0
        public var probed = 0
        public var unprobed = 0
        public init() {}
    }
    public func codecSummary() -> CodecSummary {
        let d = FetchDescriptor<MediaFile>(predicate: #Predicate { !$0.ignored && $0.item != nil })
        let files = (try? context.fetch(d)) ?? []
        var out = CodecSummary()
        var counts: [String: Int] = [:]
        for f in files {
            if f.resolution == "2160p" { out.uhd += 1 }
            if f.qualityTags.contains(where: { ["hdr", "hdr10", "hdr10+", "dv", "dolby vision", "dovi"].contains($0.lowercased()) }) { out.hdr += 1 }
            if let v = f.videoCodec, !v.isEmpty {
                out.probed += 1
                let name = v.lowercased().contains("hevc") || v.lowercased().contains("h265") || v.lowercased().contains("x265") ? "HEVC" :
                           v.lowercased().contains("h264") || v.lowercased().contains("avc") || v.lowercased().contains("x264") ? "H.264" :
                           v.lowercased().contains("av1") ? "AV1" : v.uppercased()
                counts[name, default: 0] += 1
            } else {
                out.unprobed += 1
            }
        }
        out.codecs = counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        return out
    }

    /// Keeps a file's chapter list once VLC has read it. Not synced; each device learns it on play.
    public func recordChapters(fileID: UUID, chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }
        var d = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.id == fileID }); d.fetchLimit = 1
        guard let file = try? context.fetch(d).first, file.chapterStarts != chapters.map(\.start) else { return }
        file.chapterStarts = chapters.map(\.start)
        file.chapterTitles = chapters.map(\.title)
        try? context.save()
    }

    public func recordAudioTracks(fileID: UUID, names: [String], languages: [String]) {
        guard !names.isEmpty else { return }
        var d = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.id == fileID }); d.fetchLimit = 1
        guard let file = try? context.fetch(d).first, file.audioTrackNames != names else { return }
        file.audioTrackNames = names
        file.audioTrackLanguages = languages
        try? context.save()
    }

    /// The text of each sidecar subtitle next to `file` (SRT, VTT), read from its share.
    public func sidecarSubtitles(for file: MediaFile) async -> [(name: String, data: Data)] {
        guard !file.sidecars.isEmpty, let record = file.source else { return [] }
        let source = SourceFactory.make(record.config)
        guard (try? await source.connect(credentials: CredentialStore.shared.load(for: record.id))) != nil else { return [] }
        defer { Task { await source.disconnect() } }
        var out: [(String, Data)] = []
        for path in file.sidecars where ["srt", "vtt"].contains((path as NSString).pathExtension.lowercased()) {
            var data = Data()
            var offset: Int64 = 0
            while data.count < 4 * 1024 * 1024 {
                guard let chunk = try? await source.read(path, offset: offset, length: 256 * 1024), !chunk.isEmpty else { break }
                data.append(chunk); offset += Int64(chunk.count)
                if chunk.count < 256 * 1024 { break }
            }
            if !data.isEmpty { out.append(((path as NSString).lastPathComponent, data)) } else { Diagnostics.log("airplay", "sidecar \(path) could not be read") }
        }
        return out
    }

    /// Remembers which copy to play for a title with several; nil goes back to the best resolution.
    public func setPreferredFile(_ file: MediaFile?, for item: MediaItem) {
        item.preferredFileID = file?.id
        item.updatedAt = Date(); item.pendingSync = true
        try? context.save()
        notifySync(); objectWillChange.send()
    }

    // MARK: - Artwork overrides

    public enum ArtworkSlot { case poster, backdrop, logo }
    public func setArtwork(_ url: String?, slot: ArtworkSlot, for item: MediaItem) {
        switch slot {
        case .poster: item.posterOverrideURL = url
        case .backdrop: item.backdropOverrideURL = url
        case .logo: item.logoOverrideURL = url
        }
        item.updatedAt = Date(); item.pendingSync = true
        try? context.save()
        Diagnostics.log("artwork", "\(item.title.prefix(40)) \(slot): \(url.map { Diagnostics.safe(URL(string: $0)!) } ?? "automatic")")
        notifySync(); objectWillChange.send()
    }
    public func setArtwork(_ url: String?, for collection: MediaCollection) {
        collection.artworkURL = url
        collection.updatedAt = Date(); collection.pendingSync = true
        try? context.save()
        notifySync(); objectWillChange.send()
    }
    public func setCollage(_ urls: [String], for collection: MediaCollection) {
        collection.collageURLs = Array(urls.prefix(4))
        collection.artworkURL = nil
        collection.updatedAt = Date(); collection.pendingSync = true
        try? context.save()
        notifySync(); objectWillChange.send()
    }

    // MARK: - Group artwork (universes, film series)

    public func groupArtwork(for groupID: String) -> GroupArtwork? {
        var d = FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.groupID == groupID }); d.fetchLimit = 1
        return (try? context.fetch(d).first).flatMap { $0.isEmpty ? nil : $0 }
    }
    public func allGroupArtwork() -> [String: GroupArtwork] {
        Dictionary(((try? context.fetch(FetchDescriptor<GroupArtwork>())) ?? []).filter { !$0.isEmpty }.map { ($0.groupID, $0) }, uniquingKeysWith: { a, _ in a })
    }
    /// nil url and empty collage clears the pick (the row stays, as a tombstone the other device honours).
    public func setGroupArtwork(url: String?, collage: [String], for groupID: String) {
        let g = (try? context.fetch(FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.groupID == groupID })).first) ?? { let x = GroupArtwork(groupID: groupID); context.insert(x); return x }()
        g.url = url; g.collageURLs = Array(collage.prefix(4))
        g.updatedAt = Date(); g.pendingSync = true
        try? context.save()
        notifySync(); objectWillChange.send()
    }

    // MARK: - Universes

    /// Everything the Collections screen needs in one pass over the films: universes and TMDb series
    /// with two or more films, each with its films (oldest first) and, for a universe, a studio logo.
    public struct GroupIndex: Sendable {
        public struct Group: Sendable {
            public var name: String; public var films: [MediaItem]; public var logoPath: String?; public var posterPath: String?
            /// Every distinct studio logo among the group's films (for the artwork picker).
            public var logoPaths: [String] = []
            /// fanart.tv title logo of the group's earliest film, for franchises with no studio logo.
            public var fanartLogoURL: String?
        }
        public var universes: [Group] = []
        public var series: [(id: Int, group: Group)] = []
    }
    public func groupIndex() -> GroupIndex {
        // Cached until a write or sync drops it: the Collections screen refreshes on every scan tick
        // and this pass decodes three arrays per film, a second or more on a 500-film library.
        if let groupIndexCache { return groupIndexCache }
        let index = buildGroupIndex()
        groupIndexCache = index
        return index
    }
    private func buildGroupIndex() -> GroupIndex {
        var byUniverse: [String: [MediaItem]] = [:]
        var logos: [String: String] = [:]
        var allLogos: [String: [String]] = [:]
        var bySeries: [Int: (String, String?, [MediaItem])] = [:]
        for f in items(kind: .film) {
            for u in Universes.universes(studios: f.studios, keywords: f.keywords) {
                byUniverse[u, default: []].append(f)
                for (i, s) in f.studios.enumerated() where Universes.universeName(forStudio: s) == u && i < f.studioLogos.count && !f.studioLogos[i].isEmpty {
                    if logos[u] == nil { logos[u] = f.studioLogos[i] }
                    if !(allLogos[u] ?? []).contains(f.studioLogos[i]) { allLogos[u, default: []].append(f.studioLogos[i]) }
                }
            }
            if let id = f.collectionID {
                var e = bySeries[id] ?? (f.collectionName ?? "Collection", nil, [])
                if e.1 == nil { e.1 = f.collectionPosterPath }
                e.2.append(f)
                bySeries[id] = e
            }
        }
        let byYear: (MediaItem, MediaItem) -> Bool = { ($0.year ?? 0) < ($1.year ?? 0) }
        var index = GroupIndex()
        index.universes = byUniverse.filter { $0.value.count >= 2 }
            .map { entry in
                let films = entry.value.sorted(by: byYear)
                return GroupIndex.Group(name: entry.key, films: films, logoPath: logos[entry.key], posterPath: nil, logoPaths: allLogos[entry.key] ?? [],
                                        fanartLogoURL: logos[entry.key] == nil ? films.first(where: { $0.logoURL != nil })?.logoURL : nil)
            }
            .sorted { $0.films.count != $1.films.count ? $0.films.count > $1.films.count : $0.name < $1.name }
        index.series = bySeries.filter { $0.value.2.count >= 2 }
            .map { ($0.key, GroupIndex.Group(name: $0.value.0, films: $0.value.2.sorted(by: byYear), logoPath: nil, posterPath: $0.value.1, fanartLogoURL: nil)) }
            .sorted { $0.group.films.count != $1.group.films.count ? $0.group.films.count > $1.group.films.count : $0.group.name < $1.group.name }
        return index
    }

    /// Every universe with at least two library films, biggest first.
    public func universes() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for f in items(kind: .film) { for u in Universes.universes(studios: f.studios, keywords: f.keywords) { counts[u, default: 0] += 1 } }
        return counts.filter { $0.value >= 2 }.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// A studio logo for a universe, from any of its films whose company maps to it.
    public func logoPath(forUniverse name: String) -> String? {
        for f in films(inUniverse: name) {
            for (i, s) in f.studios.enumerated() where Universes.universeName(forStudio: s) == name && i < f.studioLogos.count && !f.studioLogos[i].isEmpty {
                return f.studioLogos[i]
            }
        }
        return nil
    }

    public func films(inUniverse name: String) -> [MediaItem] {
        items(kind: .film).filter { Universes.universes(studios: $0.studios, keywords: $0.keywords).contains(name) }.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    /// TMDb film collections (series) with at least two library films, biggest first.
    public func filmCollections() -> [(id: Int, name: String, count: Int)] {
        var counts: [Int: (String, Int)] = [:]
        for f in items(kind: .film) { if let id = f.collectionID { counts[id] = (f.collectionName ?? counts[id]?.0 ?? "Collection", (counts[id]?.1 ?? 0) + 1) } }
        return counts.filter { $0.value.1 >= 2 }.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 < $1.1 }
    }

    // MARK: - Film collections

    /// Library films in the same TMDb collection, oldest first, the given film excluded.
    public func films(inCollection id: Int, excluding key: String) -> [MediaItem] {
        items(kind: .film).filter { $0.collectionID == id && $0.itemKey != key }.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    /// Films matched before collections were recorded have no collection yet; fill it in from TMDb
    /// the first time their page opens.
    public func ensureCollection(for film: MediaItem, tmdb: TMDbClient) async {
        guard film.kind == .film, film.collectionCheckedAt == nil, let id = film.tmdbID else { return }
        if let d = try? await tmdb.movie(id: id) {
            film.collectionID = d.belongsToCollection?.id
            film.collectionName = d.belongsToCollection?.name
        }
        film.collectionCheckedAt = Date()
        try? context.save()
        if film.collectionID != nil { objectWillChange.send() }
    }

    /// Films matched before collections were recorded (anything before 24 Oct 2026) have none, so
    /// a film page found no siblings. Run once per launch: one TMDb detail call per film, almost all
    /// of them served from the metadata cache that the original match filled.
    public func backfillCollections(tmdb: TMDbClient) async {
        let pending = items(kind: .film, includeHidden: true).filter { f in
            f.tmdbID != nil && (f.collectionCheckedAt == nil || f.universeCheckedAt == nil
                                || (!f.studios.isEmpty && f.studioLogos.isEmpty)            // logos came later than studios
                                || (f.collectionID != nil && f.collectionPosterPath == nil))  // so did the series poster
        }
        guard !pending.isEmpty else { return }
        Diagnostics.log("library", "backfilling collections and universes for \(pending.count) films")
        var found = 0
        for (n, film) in pending.enumerated() {
            if Task.isCancelled { break }
            if let d = try? await tmdb.movie(id: film.tmdbID!) {
                film.collectionID = d.belongsToCollection?.id
                film.collectionName = d.belongsToCollection?.name
                film.studios = d.productionCompanies?.map(\.name) ?? []
                film.studioLogos = d.productionCompanies?.map { $0.logoPath ?? "" } ?? []
                film.keywords = d.keywords?.names ?? []
                film.collectionPosterPath = d.belongsToCollection?.posterPath
                if film.collectionID != nil || !Universes.universes(studios: film.studios, keywords: film.keywords).isEmpty { found += 1 }
            }
            film.collectionCheckedAt = Date()
            film.universeCheckedAt = Date()
            if n % 25 == 24 { try? context.save() }
        }
        try? context.save()
        Diagnostics.log("library", "collections backfilled: \(found) of \(pending.count) films belong to one")
        groupIndexCache = nil
        if found > 0 { objectWillChange.send() }
    }

    /// Cast photos for titles matched before profile paths were recorded: one TMDb detail call,
    /// usually served from the metadata cache, the first time the page opens.
    public func ensureCastPhotos(for item: MediaItem, tmdb: TMDbClient) async {
        guard item.castPhotosCheckedAt == nil, !item.cast.isEmpty, let id = item.tmdbID, item.kind != .episode else { return }
        var members: [TMDbCastMember] = []
        if item.kind == .film, let d = try? await tmdb.movie(id: id) { members = d.credits?.cast ?? [] }
        else if item.kind == .show, let d = try? await tmdb.show(id: id) { members = d.credits?.cast ?? [] }
        let byName = Dictionary(members.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        item.castProfiles = item.cast.map { byName[$0]?.profilePath ?? "" }
        item.castIDs = item.cast.map { byName[$0]?.id ?? 0 }
        item.castPhotosCheckedAt = Date()
        try? context.save()
        if item.castProfiles.contains(where: { !$0.isEmpty }) { objectWillChange.send() }
    }

    // MARK: - Extra artwork

    /// Fills in fanart.tv logo and background for an item the first time its detail screen opens
    /// (and again after a week). Shows need the TheTVDB id the matcher recorded; films use TMDb's id.
    public func fetchExtraArt(for item: MediaItem, fanart: FanartClient) async {
        if let at = item.extraArtCheckedAt, Date().timeIntervalSince(at) < 7 * 86_400 { return }
        let art: FanartArt
        do {
            if item.kind == .show, let tvdb = item.tvdbID { art = try await fanart.show(tvdbID: tvdb) }
            else if item.kind == .film, let id = item.tmdbID { art = try await fanart.movie(tmdbID: id) }
            else { return }
        } catch {
            Diagnostics.log("artwork", "fanart for \(item.title.prefix(40)): \(error.localizedDescription)")
            item.extraArtCheckedAt = Date()
            try? context.save()
            return
        }
        item.logoURL = art.logoURL
        item.extraBackdropURL = art.backgroundURLs.first
        item.extraArtCheckedAt = Date()
        try? context.save()
        if !art.isEmpty { objectWillChange.send() }
    }

    // MARK: - Watch state

    public func watchState(_ key: String) -> WatchState? {
        if watchCache == nil { watchCache = Dictionary(watchStates().map { ($0.itemKey, $0) }, uniquingKeysWith: { a, _ in a }) }
        return watchCache?[key]
    }

    /// All watch states for a set of keys in one query, keyed by item key.
    public func watchStates(for keys: [String]) -> [String: WatchState] {
        guard !keys.isEmpty else { return [:] }
        let d = FetchDescriptor<WatchState>(predicate: #Predicate { keys.contains($0.itemKey) })
        return Dictionary(uniqueKeysWithValues: ((try? context.fetch(d)) ?? []).map { ($0.itemKey, $0) })
    }

    public func watchStates() -> [WatchState] {
        (try? context.fetch(FetchDescriptor<WatchState>(sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)]))) ?? []
    }

    public func recordProgress(itemKey: String, position: TimeInterval, duration: TimeInterval) {
        let ws = watchState(itemKey) ?? { let w = WatchState(itemKey: itemKey, deviceID: deviceID); context.insert(w); return w }()
        ws.position = position
        ws.duration = duration
        ws.lastPlayedAt = Date()
        ws.updatedAt = Date()
        ws.deviceID = deviceID
        ws.pendingSync = true
        if duration > 0 {
            let fraction = position / duration
            if fraction >= 0.95 {
                ws.watched = true
            } else if fraction > 0.02 {
                // Replaying something already watched and stopping part-way puts it back into
                // Continue Watching; the tick returns once it is finished again.
                ws.watched = false
            }
        }
        try? context.save()
        notifySync()
    }

    /// Drops an item from Continue Watching: position back to zero, not marked watched.
    public func clearProgress(itemKey: String) {
        guard let ws = watchState(itemKey) else { return }
        ws.position = 0
        ws.watched = false
        ws.updatedAt = Date()
        ws.pendingSync = true
        try? context.save()
        objectWillChange.send()
        notifySync()
    }

    /// One save and one sync push for a whole season or show.
    public func setWatched(_ watched: Bool, itemKeys: [String]) {
        for key in itemKeys {
            let ws = watchState(key) ?? { let w = WatchState(itemKey: key, deviceID: deviceID); context.insert(w); return w }()
            ws.watched = watched
            if !watched { ws.position = 0 }
            ws.updatedAt = Date(); ws.pendingSync = true
        }
        try? context.save()
        notifySync()
    }

    /// A film that is watched, or a show with no unwatched episodes.
    public func isFullyWatched(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .show: !item.episodes.isEmpty && unwatchedCount(item) == 0
        default: watchState(item.itemKey)?.watched == true
        }
    }

    public func setWatched(_ watched: Bool, itemKey: String) {
        let ws = watchState(itemKey) ?? { let w = WatchState(itemKey: itemKey, deviceID: deviceID); context.insert(w); return w }()
        ws.watched = watched
        if !watched { ws.position = 0 }
        ws.updatedAt = Date(); ws.pendingSync = true
        try? context.save()
        notifySync()
    }

    /// Episodes in progress plus films in progress, most recent first.
    public func continueWatching(limit: Int = 12) -> [(MediaItem, WatchState)] {
        watchStates().filter(\.isInProgress).compactMap { ws in item(ws.itemKey).map { ($0, ws) } }.prefix(limit).map { $0 }
    }

    /// Episodes in viewing order. Specials (season 0) only take part when `includingSpecials`,
    /// i.e. when the viewer is already inside season 0.
    private func orderedEpisodes(of show: MediaItem, includingSpecials: Bool) -> [MediaItem] {
        show.episodes
            .filter { includingSpecials || ($0.seasonNumber ?? 0) > 0 }
            .sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
    }

    /// The episode the viewer most recently played in this show, with when.
    private func lastPlayed(in show: MediaItem, states: [String: WatchState]) -> (MediaItem, Date)? {
        show.episodes.compactMap { ep -> (MediaItem, Date)? in
            guard let ws = states[ep.itemKey], ws.watched || ws.isInProgress else { return nil }
            return (ep, ws.lastPlayedAt ?? ws.updatedAt)
        }.max { $0.1 < $1.1 }
    }

    /// The episode after the most recently played one, in season/episode order, crossing into the next
    /// season when needed. Whether it was watched before is irrelevant: after S03E04 comes S03E05, and a
    /// skipped S02E07 stays skipped. Nil when the last played episode was the show's final one.
    public func episodeAfterLastPlayed(in show: MediaItem, states: [String: WatchState]? = nil) -> MediaItem? {
        let states = states ?? Dictionary(uniqueKeysWithValues: watchStates().map { ($0.itemKey, $0) })
        guard let (last, _) = lastPlayed(in: show, states: states) else { return nil }
        return episodeAfter(last)
    }

    /// Next Up on Home: one entry per show with viewing history, most recently watched show first.
    /// A show whose last played episode is still in progress belongs to Continue Watching instead.
    public func nextUp(limit: Int = 12) -> [MediaItem] {
        // Start from what was played, newest first, and visit only those shows: walking every episode of
        // every show faulted the whole library in before Home could draw.
        var d = FetchDescriptor<WatchState>(predicate: #Predicate { $0.lastPlayedAt != nil }, sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        d.fetchLimit = 60
        let recent = (try? context.fetch(d)) ?? []
        let states = Dictionary(uniqueKeysWithValues: watchStates().map { ($0.itemKey, $0) })
        var seenShows = Set<String>()
        var candidates: [(MediaItem, Date)] = []
        for ws in recent {
            guard let ep = item(ws.itemKey), ep.kind == .episode, let show = ep.show, !show.hidden, seenShows.insert(show.itemKey).inserted else { continue }
            guard let (last, when) = lastPlayed(in: show, states: states) else { continue }
            if states[last.itemKey]?.isInProgress == true { continue }
            if let next = episodeAfter(last) { candidates.append((next, when)) }
            if candidates.count >= limit { break }
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Newest films and shows, by when they entered the library.
    public func recentlyAdded(limit: Int = 12) -> [MediaItem] {
        let film = MediaKind.film.rawValue, show = MediaKind.show.rawValue
        var d = FetchDescriptor<MediaItem>(predicate: #Predicate { ($0.kindRaw == film || $0.kindRaw == show) && !$0.hidden }, sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    /// Files with no match plus titles matched on a weak signal: both wait in Needs Review.
    public func reviewCount() -> Int {
        let d = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.classificationRaw == "review" && !$0.reviewed && !$0.ignored })
        return ((try? context.fetchCount(d)) ?? 0) + lowConfidenceItems().count
    }

    /// Films and shows the matcher took on a weak signal (`autoLow`), for the viewer to confirm or fix.
    public func lowConfidenceItems() -> [MediaItem] {
        let low = MatchConfidence.autoLow.rawValue
        let d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.confidenceRaw == low && !$0.hidden && !$0.pendingDeletion && ($0.kindRaw == "film" || $0.kindRaw == "show") }, sortBy: [SortDescriptor(\.sortTitle)])
        return (try? context.fetch(d)) ?? []
    }

    /// The viewer looked at a weak match and kept it.
    public func confirmMatch(_ item: MediaItem) throws {
        item.confidenceRaw = MatchConfidence.manual.rawValue
        item.pendingSync = true; item.updatedAt = Date()
        for f in (item.kind == .show ? item.episodes.flatMap(\.files) : item.files) {
            if f.classificationRaw == "episode-low" { f.classificationRaw = "episode" }
            f.reviewed = true; f.pendingSync = true; f.updatedAt = Date()
        }
        try context.save()
        notifySync()
    }

    /// The show page's Play button: the episode still in progress if there is one, else the one after
    /// the last played, else the first episode.
    public func nextEpisode(of show: MediaItem) -> MediaItem? {
        let states = Dictionary(uniqueKeysWithValues: watchStates().map { ($0.itemKey, $0) })
        if let (last, _) = lastPlayed(in: show, states: states), states[last.itemKey]?.isInProgress == true { return last }
        return episodeAfterLastPlayed(in: show, states: states)
            ?? orderedEpisodes(of: show, includingSpecials: false).first
            ?? orderedEpisodes(of: show, includingSpecials: true).first
    }

    /// The episode preceding `episode` in season/episode order; specials only precede specials.
    public func episodeBefore(_ episode: MediaItem) -> MediaItem? {
        guard let show = episode.show else { return nil }
        let eps = orderedEpisodes(of: show, includingSpecials: (episode.seasonNumber ?? 0) == 0)
        guard let i = eps.firstIndex(where: { $0.itemKey == episode.itemKey }), i > 0 else { return nil }
        return eps[i - 1]
    }

    /// The episode following `episode` in season/episode order; specials only follow specials.
    public func episodeAfter(_ episode: MediaItem) -> MediaItem? {
        guard let show = episode.show else { return nil }
        let eps = orderedEpisodes(of: show, includingSpecials: (episode.seasonNumber ?? 0) == 0)
        guard let i = eps.firstIndex(where: { $0.itemKey == episode.itemKey }), i + 1 < eps.count else { return nil }
        return eps[i + 1]
    }

    public func unwatchedCount(_ show: MediaItem) -> Int {
        show.episodes.filter { watchState($0.itemKey)?.watched != true }.count
    }

    // MARK: - Favourites

    public func isFavourite(_ key: String) -> Bool {
        if favouriteCache == nil {
            let d = FetchDescriptor<Favourite>(predicate: #Predicate { $0.deletedAt == nil })
            favouriteCache = Set(((try? context.fetch(d)) ?? []).map(\.itemKey))
        }
        return favouriteCache?.contains(key) ?? false
    }

    public func favourites() -> [MediaItem] {
        let d = FetchDescriptor<Favourite>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return ((try? context.fetch(d)) ?? []).compactMap { item($0.itemKey) }
    }

    public func toggleFavourite(_ key: String) {
        if let f = favourite(key) {
            f.deletedAt = f.isActive ? Date() : nil
            if f.isActive { f.createdAt = Date() }
            f.updatedAt = Date(); f.pendingSync = true
        } else {
            context.insert(Favourite(itemKey: key))
        }
        try? context.save()
        objectWillChange.send()
        notifySync()
    }

    private func favourite(_ key: String) -> Favourite? {
        var d = FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key }); d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: - Collections

    public func collections() -> [MediaCollection] {
        (try? context.fetch(FetchDescriptor<MediaCollection>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    public func addCollection(named name: String) { context.insert(MediaCollection(name: name)); try? context.save(); notifySync() }

    public func toggle(_ key: String, in collection: MediaCollection) {
        if let i = collection.itemKeys.firstIndex(of: key) { collection.itemKeys.remove(at: i) } else { collection.itemKeys.append(key) }
        collection.updatedAt = Date(); collection.pendingSync = true
        try? context.save()
        notifySync()
    }

    // MARK: - Playback URL

    /// Resolves a playable URL for the preferred (or given) file of an item, connecting to its source.
    /// `status` is told what is going on while that takes a while (waking a sleeping NAS).
    public func playbackURL(for file: MediaFile, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (URL, [URL]) {
        guard let record = file.source else { throw SourceError.notFound(file.relativePath) }
        let source = SourceFactory.make(record.config)
        let creds = CredentialStore.shared.load(for: record.id)
        let name = record.name, mac = record.macAddress
        do {
            try await source.connect(credentials: creds)
        } catch SourceError.unreachable(let host) where mac != nil {
            // The NAS may just be asleep. Send Wake-on-LAN and keep trying for a while; a Synology takes
            // 30–90 s to answer SMB after the packet. Each attempt is itself ~20 s of timeouts.
            status("Waking \(name)…")
            Diagnostics.log("source", "\(host) unreachable; sending Wake-on-LAN to \(name)")
            try? await WakeOnLAN.wake(mac: mac!)
            let deadline = Date().addingTimeInterval(90)
            var attempt = 0
            while true {
                attempt += 1
                try await Task.sleep(for: .seconds(5))
                do {
                    try await source.connect(credentials: creds)
                    Diagnostics.log("source", "\(name) answered after wake, attempt \(attempt)")
                    break
                } catch {
                    if Date() > deadline {
                        Diagnostics.log("source", "\(name) still unreachable \(Int(Date().timeIntervalSince(deadline) + 90))s after wake")
                        throw error
                    }
                    status("Waking \(name)… still waiting (\(attempt))")
                }
            }
        }
        let url = try await source.playbackURL(file.relativePath, credentials: creds)
        var subs: [URL] = []
        for s in file.sidecars { if let u = try? await source.playbackURL(s, credentials: creds) { subs.append(u) } }
        return (url, subs)
    }

    /// A connected source for one file, for the local HTTP bridge (AirPlay video from a share).
    /// The caller owns it and disconnects it; the bridge does that when it stops.
    public func streamSource(for file: MediaFile) async throws -> (source: any MediaSource, path: String, size: Int64) {
        guard let record = file.source else { throw SourceError.notFound(file.relativePath) }
        let source = SourceFactory.make(record.config)
        try await source.connect(credentials: CredentialStore.shared.load(for: record.id))
        let size = file.size > 0 ? file.size : ((try? await source.stat(file.relativePath).size) ?? 0) ?? 0
        return (source, file.relativePath, size)
    }

    /// Highest resolution first; ties broken by size.
    public func preferredFile(_ item: MediaItem) -> MediaFile? {
        if let id = item.preferredFileID, let chosen = item.files.first(where: { $0.id == id && !$0.ignored }) { return chosen }
        return item.files.filter { !$0.ignored }.max { a, b in
            (Self.resolutionRank(a.resolution), a.size) < (Self.resolutionRank(b.resolution), b.size)
        }
    }

    static func resolutionRank(_ r: String?) -> Int {
        switch r { case "2160p": 4; case "1080p": 3; case "720p": 2; case "576p", "480p": 1; default: 0 }
    }
}

/// Wraps `UIApplication.beginBackgroundTask` so a scan survives the user switching apps for a few
/// minutes. On platforms without it (macOS tests) it is a no-op.
@MainActor
final class BackgroundAssertion {
    #if canImport(UIKit) && !os(macOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    #else
    init(name: String) {}
    func end() {}
    #endif
}
#endif
