import Foundation
import SwiftData
import MediaCore
import MediaSources
import Metadata

// Audiobooks: books, covers, tags and catalogue lookups.
@MainActor
extension LibraryStore {
    // MARK: - Audiobooks

    /// Books in series order: series name, then the book's number in it, then title.
    public func audiobooks() -> [MediaItem] {
        items(kind: .audiobook).sorted { ($0.seriesName ?? $0.sortTitle, $0.seriesIndex ?? 0, $0.sortTitle) < ($1.seriesName ?? $1.sortTitle, $1.seriesIndex ?? 0, $1.sortTitle) }
    }
    /// Where covers read from the files live. Per device; the path stored on the item is the file name.
    nonisolated public static var coversDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated public static func coverURL(_ item: MediaItem) -> URL? {
        guard let name = item.coverPath ?? item.show?.coverPath else { return nil }
        let url = coversDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// What the first part's tags said: a title and author override the names, the cover is kept as a file.
    public func applyBookTags(_ book: MediaItem, title: String?, author: String?, narrator: String?, year: Int?, cover: Data?) {
        if let title, !title.isEmpty {
            // "Command Decision: Vatta's War, Book 4 (Unabridged)" → title, series and number.
            let parsed = AudiobookGrouper.parseBookName(title)
            book.title = parsed.title; book.sortTitle = MediaItem.makeSortTitle(parsed.title)
            if let s = parsed.series { book.seriesName = s; book.seriesIndex = parsed.seriesIndex ?? book.seriesIndex }
        }
        if let author, !author.isEmpty { book.author = author }
        if let narrator, !narrator.isEmpty { book.narrator = narrator }
        if let year, book.year == nil { book.year = year }
        if let cover, !cover.isEmpty {
            let name = book.itemKey.replacingOccurrences(of: ":", with: "-") + ".jpg"
            try? cover.write(to: Self.coversDirectory.appendingPathComponent(name))
            book.coverPath = name
        }
        book.tagsRead = true
        book.pendingSync = true; book.updatedAt = Date()
        try? context.save()
        invalidateCaches()
        objectWillChange.send()
        notifySync()
    }
    /// Titles stored by an earlier build with the edition noise and series still in them are cleaned once.
    public func tidyBookTitles() {
        var changed = false
        for book in items(kind: .audiobook, includeHidden: true) {
            let parsed = AudiobookGrouper.parseBookName(book.title)
            guard parsed.title != book.title || (book.seriesName == nil && parsed.series != nil) else { continue }
            book.title = parsed.title; book.sortTitle = MediaItem.makeSortTitle(parsed.title)
            if book.seriesName == nil, let s = parsed.series { book.seriesName = s; book.seriesIndex = parsed.seriesIndex ?? book.seriesIndex }
            book.pendingSync = true; book.updatedAt = Date(); changed = true
        }
        if changed { try? context.save(); objectWillChange.send(); notifySync() }
    }
    /// Books the catalogues have not been asked about: after the tags, so the search has the best
    /// title and author the files can give.
    public func booksNeedingLookup() -> [MediaItem] { audiobooks().filter { $0.tagsRead && ($0.bookLookup == nil || $0.bookLookup == "redo-manual") } }

    /// What a catalogue said about a book. Chosen by hand it replaces everything; taken on the
    /// names it fills what the files did not say, and the names' title and author stand when the
    /// tags gave them (the tags are the edition on disk; the catalogue may be another).
    public func applyBookLookup(_ book: MediaItem, hit given: AudiobookHit, manual: Bool) {
        // Of the series the catalogue lists, the one this library already shelves the author's
        // other books under (or the tags named), else the parent series.
        var hit = given
        let known = [book.seriesName].compactMap { $0 } + items(kind: .audiobook).filter { $0 !== book && $0.author == book.author }.compactMap(\.seriesName)
        hit.chooseSeries(known: known)
        let trust = manual || !book.tagsRead
        if trust || book.title.isEmpty { book.title = hit.title; book.sortTitle = MediaItem.makeSortTitle(hit.title) }
        if let a = hit.authorLine, trust || book.author == nil { book.author = a }
        if let n = hit.narratorLine, trust || book.narrator == nil { book.narrator = n }
        // The tags' series stands on an automatic match: Audible files a book under its own series
        // names ("Vatta Universe", a "City Watch" sub-series) where the edition's tags say "Vatta's War".
        if let s = hit.series, trust || book.seriesName == nil { book.seriesName = s; book.seriesIndex = hit.seriesIndex ?? (manual ? nil : book.seriesIndex) }
        else if let mine = book.seriesName, book.seriesIndex == nil, let i = hit.seriesIndex, let theirs = hit.series, MediaItem.makeSortTitle(mine) == MediaItem.makeSortTitle(theirs) { book.seriesIndex = i }
        else if manual { book.seriesName = nil; book.seriesIndex = nil }
        if let y = hit.year, trust || book.year == nil { book.year = y }
        if let s = hit.summary, !s.isEmpty { book.overview = s }
        if let m = hit.runtimeMinutes { book.runtimeMinutes = m }
        if !hit.genres.isEmpty { book.genres = hit.genres }
        if let c = hit.coverURL { book.posterOverrideURL = c }
        book.asin = hit.asin ?? (manual ? nil : book.asin)
        book.bookLookup = manual ? "manual" : "matched"
        book.pendingSync = true; book.updatedAt = Date()
        try? context.save()
        invalidateCaches(); objectWillChange.send(); notifySync()
    }
    /// An earlier build could add the same folder rule twice; the extras go, keeping the first.
    public func dedupeFolderRules() {
        var removed = 0
        for record in sources() {
            var seen = Set<String>()
            for rule in record.folderRules.sorted(by: { $0.folderPath < $1.folderPath }) {
                if seen.contains(rule.folderPath.lowercased()) { context.delete(rule); removed += 1 } else { seen.insert(rule.folderPath.lowercased()) }
            }
        }
        if removed > 0 { try? context.save(); Diagnostics.log("library", "removed \(removed) duplicate folder rules") }
    }

    /// Once per device: books matched by an earlier build, whose catalogue series overwrote the
    /// tags', read their tags again and are looked up again under the current rules.
    public func redoBookLookupsOnce(key: String) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var n = 0
        for book in items(kind: .audiobook, includeHidden: true) where book.bookLookup == "matched" || book.bookLookup == "manual" {
            // With an ASIN the lookup refreshes the same edition; without, the tags are read again first.
            if book.asin == nil { book.tagsRead = false }
            book.bookLookup = book.bookLookup == "manual" ? "redo-manual" : nil
            book.pendingSync = true; book.updatedAt = Date(); n += 1
        }
        if n > 0 { try? context.save(); Diagnostics.log("library", "redoing tags and catalogue lookups for \(n) books") }
        UserDefaults.standard.set(true, forKey: key)
    }
    /// Nothing in the catalogues was close enough; the names and tags stand, and Fix match waits.
    public func markBookUnmatched(_ book: MediaItem) {
        book.bookLookup = "none"; book.pendingSync = true; book.updatedAt = Date()
        try? context.save()
    }
    /// Forget a lookup so the next pass asks again (a title corrected by hand, say).
    public func resetBookLookup(_ book: MediaItem) {
        book.bookLookup = nil; book.pendingSync = true; book.updatedAt = Date()
        try? context.save()
    }

    /// Books whose tags have not been read yet, with the file to read them from.
    public func booksNeedingTags() -> [(MediaItem, MediaFile)] {
        audiobooks().filter { !$0.tagsRead }.compactMap { b in
            b.episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }.first?.files.first.map { (b, $0) }
        }
    }

    public func item(_ key: String) -> MediaItem? {
        var d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key }); d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func search(_ query: String) -> [MediaItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Titles, and for books the author, series and narrator; episode titles too, so "Remnants"
        // finds the episode as well as the show. A book's parts are reached through the book.
        let d = FetchDescriptor<MediaItem>(predicate: #Predicate {
            !$0.hidden && ($0.title.localizedStandardContains(q) || $0.author?.localizedStandardContains(q) == true
                || $0.seriesName?.localizedStandardContains(q) == true || $0.narrator?.localizedStandardContains(q) == true)
        }, sortBy: [SortDescriptor(\.sortTitle)])
        let hits = ((try? context.fetch(d)) ?? []).filter { $0.kind == .episode ? ($0.show?.kind != .audiobook && !$0.files.isEmpty && $0.show?.hidden != true) : Self.playable($0) }
        // Whole titles first, then the episodes that matched by name.
        return hits.filter { $0.kind != .episode } + hits.filter { $0.kind == .episode }
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

    /// Reviewed files whose decision left them unmatched (a placeholder, or nothing) come back to
    /// the list: see `MediaFile.needsReview`.
    public func filesNeedingReview() -> [MediaFile] {
        let d = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.classificationRaw == "review" && !$0.ignored && (!$0.reviewed || $0.item == nil || $0.item?.confidenceRaw == "unmatched") }, sortBy: [SortDescriptor(\.relativePath)])
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
}
