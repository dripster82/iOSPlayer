#if canImport(SwiftData)
import Foundation
import SwiftData
import MediaCore
import MediaSources
import Metadata

/// Main-thread façade over the model container: queries the views need, plus the write
/// operations that must also mark rows for sync. Heavy work (scanning) runs on `Scanner`.
@MainActor
public final class LibraryStore: ObservableObject {
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public let deviceID: String

    @Published public private(set) var scanProgress: [UUID: ScanProgress] = [:]
    @Published public var lastError: String?
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
        let record = SourceRecord(config: config)
        for (path, tag) in folderRules {
            let rule = FolderRule(folderPath: path, tag: tag, includeInScan: tag != .excluded)
            rule.source = record
            record.folderRules.append(rule)
        }
        context.insert(record)
        try context.save()
        if let credentials { try CredentialStore.shared.save(credentials, for: config.id) }
        return record
    }

    public func removeSource(_ record: SourceRecord) throws {
        scanTasks[record.id]?.cancel()
        CredentialStore.shared.remove(for: record.id)
        context.delete(record)
        try context.save()
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
    }

    public func isScanning(_ id: UUID) -> Bool { scanTasks[id] != nil }

    public func scan(_ record: SourceRecord, tmdb: TMDbClient?) {
        guard scanTasks[record.id] == nil else { return }
        let id = record.id
        let creds = CredentialStore.shared.load(for: id)
        let scanner = LibraryScanner(modelContainer: container)
        scanTasks[id] = Task { [weak self] in
            do {
                try await scanner.scan(sourceID: id, credentials: creds, tmdb: tmdb) { p in
                    Task { @MainActor [weak self] in self?.scanProgress[id] = p }
                }
            } catch {
                await MainActor.run { [weak self] in self?.lastError = error.localizedDescription }
            }
            await MainActor.run { [weak self] in
                self?.scanTasks[id] = nil
                self?.objectWillChange.send()
            }
        }
    }

    public func scanAll(tmdb: TMDbClient?) { sources().forEach { scan($0, tmdb: tmdb) } }

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
        for f in item.files { let o = override(for: f); o.hidden = true; o.updatedAt = Date(); o.pendingSync = true }
        try context.save()
    }

    // MARK: - Review and fix match

    public func resolveReview(_ file: MediaFile, as kind: MediaKind?, tmdbID: Int?, tmdb: TMDbClient) async throws {
        let o = override(for: file)
        o.forcedKindRaw = kind?.rawValue
        o.forcedTMDbID = tmdbID
        o.updatedAt = Date(); o.pendingSync = true
        file.reviewed = true
        file.classificationRaw = kind == .episode ? "episode" : "film"
        try context.save()
        let matcher = Matcher(context: context, tmdb: tmdb)
        _ = await matcher.match(file)
        try context.save()
    }

    public func ignoreFile(_ file: MediaFile) throws {
        file.ignored = true
        let o = override(for: file); o.hidden = true; o.updatedAt = Date(); o.pendingSync = true
        try context.save()
    }

    /// Re-points every file of an item at a different TMDb entry. Used by Fix Match.
    public func fixMatch(_ item: MediaItem, tmdbID: Int, kind: MediaKind, tmdb: TMDbClient) async throws {
        let files = item.files
        for f in files {
            let o = override(for: f)
            o.forcedTMDbID = tmdbID
            o.forcedKindRaw = kind.rawValue
            o.updatedAt = Date(); o.pendingSync = true
            f.item = nil
        }
        if item.files.isEmpty, item.kind != .show { context.delete(item) }
        try context.save()
        let matcher = Matcher(context: context, tmdb: tmdb)
        for f in files { _ = await matcher.match(f) }
        try context.save()
    }

    private func override(for file: MediaFile) -> ItemOverride {
        let key = ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: file.duration)
        var d = FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key }); d.fetchLimit = 1
        if let o = try? context.fetch(d).first { return o }
        let o = ItemOverride(fileKey: key)
        context.insert(o)
        return o
    }

    // MARK: - Watch state

    public func watchState(_ key: String) -> WatchState? {
        var d = FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key }); d.fetchLimit = 1
        return try? context.fetch(d).first
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
        if duration > 0, position / duration >= 0.95 { ws.watched = true }
        try? context.save()
    }

    public func setWatched(_ watched: Bool, itemKey: String) {
        let ws = watchState(itemKey) ?? { let w = WatchState(itemKey: itemKey, deviceID: deviceID); context.insert(w); return w }()
        ws.watched = watched
        if !watched { ws.position = 0 }
        ws.updatedAt = Date(); ws.pendingSync = true
        try? context.save()
    }

    /// Episodes in progress plus films in progress, most recent first.
    public func continueWatching(limit: Int = 12) -> [(MediaItem, WatchState)] {
        watchStates().filter(\.isInProgress).compactMap { ws in item(ws.itemKey).map { ($0, ws) } }.prefix(limit).map { $0 }
    }

    /// For each show with any watch activity, the first unwatched episode after the last watched one.
    public func nextUp(limit: Int = 12) -> [MediaItem] {
        var out: [MediaItem] = []
        let states = Dictionary(uniqueKeysWithValues: watchStates().map { ($0.itemKey, $0) })
        for show in items(kind: .show) {
            let eps = show.episodes.sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
            guard eps.contains(where: { states[$0.itemKey]?.watched == true || states[$0.itemKey]?.isInProgress == true }) else { continue }
            if let next = eps.first(where: { let s = states[$0.itemKey]; return s?.watched != true && s?.isInProgress != true }) { out.append(next) }
            if out.count >= limit { break }
        }
        return out
    }

    /// First unwatched episode of a show, or the first episode.
    public func nextEpisode(of show: MediaItem) -> MediaItem? {
        let eps = show.episodes.sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
        return eps.first { watchState($0.itemKey)?.watched != true } ?? eps.first
    }

    public func episodeAfter(_ episode: MediaItem) -> MediaItem? {
        guard let show = episode.show else { return nil }
        let eps = show.episodes.sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
        guard let i = eps.firstIndex(where: { $0.itemKey == episode.itemKey }), i + 1 < eps.count else { return nil }
        return eps[i + 1]
    }

    public func unwatchedCount(_ show: MediaItem) -> Int {
        show.episodes.filter { watchState($0.itemKey)?.watched != true }.count
    }

    // MARK: - Favourites

    public func isFavourite(_ key: String) -> Bool { favourite(key)?.isActive ?? false }

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
    }

    private func favourite(_ key: String) -> Favourite? {
        var d = FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key }); d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: - Collections

    public func collections() -> [MediaCollection] {
        (try? context.fetch(FetchDescriptor<MediaCollection>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    public func addCollection(named name: String) { context.insert(MediaCollection(name: name)); try? context.save() }

    public func toggle(_ key: String, in collection: MediaCollection) {
        if let i = collection.itemKeys.firstIndex(of: key) { collection.itemKeys.remove(at: i) } else { collection.itemKeys.append(key) }
        collection.updatedAt = Date(); collection.pendingSync = true
        try? context.save()
    }

    // MARK: - Playback URL

    /// Resolves a playable URL for the preferred (or given) file of an item, connecting to its source.
    public func playbackURL(for file: MediaFile) async throws -> (URL, [URL]) {
        guard let record = file.source else { throw SourceError.notFound(file.relativePath) }
        let source = SourceFactory.make(record.config)
        let creds = CredentialStore.shared.load(for: record.id)
        try await source.connect(credentials: creds)
        let url = try await source.playbackURL(file.relativePath, credentials: creds)
        var subs: [URL] = []
        for s in file.sidecars { if let u = try? await source.playbackURL(s, credentials: creds) { subs.append(u) } }
        return (url, subs)
    }

    /// Highest resolution first; ties broken by size.
    public func preferredFile(_ item: MediaItem) -> MediaFile? {
        item.files.filter { !$0.ignored }.max { a, b in
            (Self.resolutionRank(a.resolution), a.size) < (Self.resolutionRank(b.resolution), b.size)
        }
    }

    static func resolutionRank(_ r: String?) -> Int {
        switch r { case "2160p": 4; case "1080p": 3; case "720p": 2; case "576p", "480p": 1; default: 0 }
    }
}
#endif
