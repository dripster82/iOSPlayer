import Foundation
import SwiftData
import MediaCore
import MediaSources
import Metadata

// Needs Review, Fix match, probes and chapters.
@MainActor
extension LibraryStore {
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
        var orphans = (try? context.fetch(d)) ?? []
        // Placeholders (titles TMDb did not know) whose files have gone are not worth keeping either.
        let local = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey.starts(with: "local-") })
        for p in (try? context.fetch(local)) ?? [] where p.kind != .show && p.files.isEmpty && !orphans.contains(where: { $0 === p }) { orphans.append(p) }
        for p in (try? context.fetch(local)) ?? [] where p.kind == .show && p.episodes.allSatisfy({ $0.files.isEmpty }) && !orphans.contains(where: { $0 === p }) { orphans.append(p) }
        guard !orphans.isEmpty else { return }
        for o in orphans where o.files.isEmpty { context.delete(o) }
        try? context.save()
        Diagnostics.log("library", "purged \(orphans.count) orphaned items")
    }

    func override(for file: MediaFile) -> ItemOverride {
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

    /// A photo and id found for a cast member whose titles were recorded without them: written to
    /// every title that lists the name, so the film page and Search show the face from now on.
    public func recordCastProfile(name: String, profilePath: String, id: Int) {
        var changed = false
        for item in items(withCastMember: name) {
            guard let i = item.cast.firstIndex(of: name) else { continue }
            while item.castProfiles.count < item.cast.count { item.castProfiles.append("") }
            while item.castIDs.count < item.cast.count { item.castIDs.append(0) }
            if item.castProfiles[i].isEmpty, !profilePath.isEmpty { item.castProfiles[i] = profilePath; changed = true }
            if item.castIDs[i] == 0, id != 0 { item.castIDs[i] = id; changed = true }
        }
        if changed { try? context.save(); objectWillChange.send() }
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
        recordProbe(file, videoCodec: videoCodec, audio: audio, subtitles: subtitles, duration: duration)
    }
    /// Files nothing has read yet: no length and no codec. The background probe works through them.
    public func filesNeedingProbe(limit: Int = 25) -> [MediaFile] {
        let browsed = "browsed"
        var d = FetchDescriptor<MediaFile>(predicate: #Predicate<MediaFile> { file in
            file.duration == nil && file.videoCodec == nil && !file.ignored && file.classificationRaw != browsed
        }, sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        d.fetchLimit = limit * 2
        return ((try? context.fetch(d)) ?? []).filter { $0.item != nil }.prefix(limit).map { $0 }
    }
    public func recordProbe(_ file: MediaFile, videoCodec: String?, audio: String?, subtitles: String?, duration: TimeInterval, resolution: String? = nil) {
        var changed = false
        if let r = resolution, r != file.resolution { file.resolution = r; changed = true }
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
}
