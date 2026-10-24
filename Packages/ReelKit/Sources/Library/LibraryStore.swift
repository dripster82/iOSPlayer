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
    public func invalidateCaches() { watchCache = nil; favouriteCache = nil }
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

    public func resolveReview(_ file: MediaFile, as kind: MediaKind?, tmdbID: Int?, tmdb: TMDbClient) async throws {
        let o = override(for: file)
        o.forcedKindRaw = kind?.rawValue
        o.forcedTMDbID = tmdbID
        o.updatedAt = Date(); o.pendingSync = true
        file.reviewed = true
        file.classificationRaw = kind == .episode ? "episode" : "film"
        file.pendingSync = true; file.updatedAt = Date()
        try context.save()
        let matcher = Matcher(context: context, tmdb: tmdb)
        _ = await matcher.match(file)
        try context.save()
        notifySync()
    }

    /// Same decision for a whole folder of review items: one TMDb lookup per file, one save, one sync.
    public func resolveReview(_ files: [MediaFile], as kind: MediaKind?, tmdbID: Int?, tmdb: TMDbClient) async throws {
        let matcher = Matcher(context: context, tmdb: tmdb)
        for file in files {
            let o = override(for: file)
            o.forcedKindRaw = kind?.rawValue
            o.forcedTMDbID = tmdbID
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
    public func fixMatch(_ item: MediaItem, tmdbID: Int, kind: MediaKind, tmdb: TMDbClient) async throws {
        let files = item.files
        for f in files {
            let o = override(for: f)
            o.forcedTMDbID = tmdbID
            o.forcedKindRaw = kind.rawValue
            o.updatedAt = Date(); o.pendingSync = true
            f.item = nil
        }
        var deleted: [String] = []
        if item.files.isEmpty, item.kind != .show { deleted.append(SyncKeys.item(item.itemKey)); context.delete(item) }
        try context.save()
        let matcher = Matcher(context: context, tmdb: tmdb)
        for f in files { _ = await matcher.match(f) }
        try context.save()
        if !deleted.isEmpty { syncHooks?.deleted(deleted) }
        notifySync()
    }

    private func override(for file: MediaFile) -> ItemOverride {
        let key = ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: file.duration)
        var d = FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key }); d.fetchLimit = 1
        if let o = try? context.fetch(d).first { return o }
        let o = ItemOverride(fileKey: key)
        context.insert(o)
        return o
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
        let pending = items(kind: .film, includeHidden: true).filter { $0.collectionCheckedAt == nil && $0.tmdbID != nil }
        guard !pending.isEmpty else { return }
        Diagnostics.log("library", "backfilling collections for \(pending.count) films")
        var found = 0
        for (n, film) in pending.enumerated() {
            if Task.isCancelled { break }
            if let d = try? await tmdb.movie(id: film.tmdbID!) {
                film.collectionID = d.belongsToCollection?.id
                film.collectionName = d.belongsToCollection?.name
                if film.collectionID != nil { found += 1 }
            }
            film.collectionCheckedAt = Date()
            if n % 25 == 24 { try? context.save() }
        }
        try? context.save()
        Diagnostics.log("library", "collections backfilled: \(found) of \(pending.count) films belong to one")
        if found > 0 { objectWillChange.send() }
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
        let states = Dictionary(uniqueKeysWithValues: watchStates().map { ($0.itemKey, $0) })
        var candidates: [(MediaItem, Date)] = []
        for show in items(kind: .show) {
            guard let (last, when) = lastPlayed(in: show, states: states) else { continue }
            if states[last.itemKey]?.isInProgress == true { continue }
            if let next = episodeAfter(last) { candidates.append((next, when)) }
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
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
