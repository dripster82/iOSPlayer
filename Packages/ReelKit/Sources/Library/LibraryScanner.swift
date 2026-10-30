#if canImport(SwiftData)
import Foundation
import SwiftData
import MediaCore
import MediaSources
import Metadata

/// Progress the UI shows in a banner while a scan runs.
public struct ScanProgress: Sendable, Equatable {
    public var sourceID: UUID
    public var sourceName: String
    public var filesSeen: Int
    public var filesNew: Int
    public var matched: Int
    public var needsReview: Int
    public var phase: Phase
    /// Files the matcher could not resolve this pass (network/TMDb errors). Retried on the next scan.
    public var skipped: Int = 0
    /// The last matcher error, so the UI can say why a library is still empty.
    public var lastError: String? = nil
    /// Files the matching phase set out to resolve this pass, and how many it has dealt with so far.
    public var matchTotal: Int = 0
    public var matchDone: Int { matched + needsReview + skipped }
    public enum Phase: String, Sendable { case connecting, listing, classifying, matching, done, failed }
}

/// Walks a source, upserts `MediaFile`s, classifies them, and hands matchable ones to `Matcher`.
/// One source at a time, breadth-first, incremental by (path, size, modified). PLAN.md §11.3.
@ModelActor
public actor LibraryScanner {

    public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    /// Returns the CloudKit record names of files dropped because they sit outside the chosen folders.
    @discardableResult
    /// `scope` limits the pass to one folder (and its subfolders): the detail page's pull to refresh.
    /// Files elsewhere on the source are neither listed nor judged gone.
    public func scan(sourceID: UUID, credentials: Credentials?, providers: MetadataProviders, scope: String? = nil, progress: ProgressHandler? = nil) async throws -> [String] {
        guard let record = try fetchSource(sourceID) else { throw SourceError.notFound(sourceID.uuidString) }
        var report = ScanProgress(sourceID: sourceID, sourceName: record.name, filesSeen: 0, filesNew: 0, matched: 0, needsReview: 0, phase: .connecting)
        progress?(report)

        let source = SourceFactory.make(record.config)
        do {
            try await source.connect(credentials: credentials)
        } catch let e as SourceError {
            if case .authFailed = e { record.status = .authFailed } else { record.status = .offline }
            try modelContext.save()
            report.phase = .failed
            progress?(report)
            throw e
        }
        record.status = .scanning
        try modelContext.save()

        // Roots: tagged folders that are included, or the source root when none are tagged.
        // A folder ticked inside another ticked folder is walked once, as part of its parent.
        let included = record.folderRules.filter(\.includeInScan).map(\.folderPath)
        let roots = included.filter { r in !included.contains { o in o != r && (o.isEmpty || r.hasPrefix(o.hasSuffix("/") ? o : o + "/")) } }
        var queue = scope.map { [$0] } ?? (roots.isEmpty ? [""] : roots)
        var seenPaths = Set<String>()
        /// Every folder that listed without error, with the names it contained. A file is only treated
        /// as gone when a listing that should have shown it (or one of its parent folders) did not;
        /// a folder that failed to list, or a share that dropped mid-scan, proves nothing.
        var listed: [String: Set<String>] = [:]
        let existing = Dictionary(record.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        report.phase = .listing
        /// Audio files found under each audiobooks-tagged folder, grouped into books once the walk is done.
        var audioByRoot: [String: [String]] = [:]

        while !queue.isEmpty {
            try Task.checkCancellation()
            let dir = queue.removeFirst()
            if let tag = record.tag(for: dir), tag == .excluded { continue }
            let entries: [DirectoryEntry]
            do { entries = try await source.list(dir) } catch {
                // One bad folder shouldn't kill the scan; a root that will not list is worth a line, though.
                if roots.contains(dir) { Diagnostics.log("scan", "\(record.name): could not list \(dir.isEmpty ? "/" : dir): \(error.localizedDescription)") }
                continue
            }
            listed[dir] = Set(entries.map(\.name))

            let videos = entries.filter { !$0.isDirectory && $0.isVideo }
            let subs = entries.filter { !$0.isDirectory && $0.isSubtitle }
            for e in entries where e.isDirectory && !DirectoryEntry.isSystemFolder(e.name) { queue.append(e.relativePath) }

            if let root = record.audiobooksRoot(for: dir) {
                for a in entries where !a.isDirectory && a.isAudio {
                    seenPaths.insert(a.relativePath)
                    report.filesSeen += 1
                    audioByRoot[root, default: []].append(a.relativePath)
                    if let file = existing[a.relativePath] {
                        file.lastSeenAt = Date()
                        if file.size != (a.size ?? file.size) || file.modified != a.modified { file.size = a.size ?? file.size; file.modified = a.modified; file.pendingSync = true; file.updatedAt = Date() }
                        if file.classificationRaw != "audio" { file.classificationRaw = "audio"; file.pendingSync = true; file.updatedAt = Date() }
                    } else {
                        let file = MediaFile(relativePath: a.relativePath, size: a.size ?? 0, modified: a.modified, source: record)
                        file.classificationRaw = "audio"
                        file.pendingSync = true; file.updatedAt = Date()
                        modelContext.insert(file)
                        report.filesNew += 1
                    }
                }
            }

            for v in videos {
                seenPaths.insert(v.relativePath)
                report.filesSeen += 1
                let sidecars = subs.filter { ($0.name as NSString).deletingPathExtension.hasPrefix((v.name as NSString).deletingPathExtension) }.map(\.relativePath)
                if let file = existing[v.relativePath] {
                    file.lastSeenAt = Date()
                    file.sidecars = sidecars
                    if file.size != (v.size ?? file.size) || file.modified != v.modified {
                        file.size = v.size ?? file.size
                        file.modified = v.modified
                        file.classificationRaw = "pending"
                        file.item = nil
                        file.pendingSync = true; file.updatedAt = Date()
                    }
                } else {
                    let file = MediaFile(relativePath: v.relativePath, size: v.size ?? 0, modified: v.modified, source: record)
                    file.sidecars = sidecars
                    file.pendingSync = true; file.updatedAt = Date()
                    modelContext.insert(file)
                    report.filesNew += 1
                }
            }
            // One folder, one save, then a breath: the main context merges each save, and a few hundred
            // rows at a time keeps that merge (and the screens it redraws) short while the scan runs.
            try modelContext.save()
            if report.filesSeen % 50 == 0 { progress?(report) }
            await Task.yield()
        }

        // Books: the audio files under each audiobooks folder, grouped by `AudiobookGrouper`.
        let bookRoots = record.folderRules.filter { $0.tag == .audiobooks && $0.includeInScan }.map(\.folderPath)
        if !bookRoots.isEmpty { Diagnostics.log("scan", "\(record.name): audiobook folders \(bookRoots.map { $0.isEmpty ? "/" : $0 }.joined(separator: ", ")); audio files found: \(audioByRoot.map { "\($0.key.isEmpty ? "/" : $0.key) \($0.value.count)" }.joined(separator: ", ").ifEmpty("none"))") }
        for (root, paths) in audioByRoot {
            let books = AudiobookGrouper.books(files: paths, root: root)
            let made = upsertBooks(books, record: record)
            report.matched += made
            Diagnostics.log("scan", "\(record.name): \(books.count) audiobooks under \(root.isEmpty ? "/" : root) (\(paths.count) files, \(made) new)")
        }
        try modelContext.save()

        // Files outside every included root (rules changed, or a merged source record briefly had none)
        // leave the library; the next device learns through the sync deletions.
        var droppedKeys: [String] = []
        if scope == nil, !roots.isEmpty {
            let excluded = record.folderRules.filter { !$0.includeInScan }.map(\.folderPath)
            func under(_ path: String, _ folders: [String]) -> Bool {
                folders.contains { $0.isEmpty || path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            }
            for file in record.files where !under(file.relativePath, roots) || under(file.relativePath, excluded) {
                droppedKeys.append(SyncKeys.file(sourceID: sourceID, relativePath: file.relativePath))
                modelContext.delete(file)
            }
            if !droppedKeys.isEmpty { try modelContext.save() }
        }

        // Files that have gone from the share leave the library, and so do titles left with no files
        // (retired the gentle way: hidden and purged at the next launch, in case a page is showing one).
        func isGone(_ path: String) -> Bool {
            var dir = ""
            for part in path.split(separator: "/").map(String.init) {
                if let names = listed[dir] { if !names.contains(part) { return true } } 
                dir = dir.isEmpty ? part : dir + "/" + part
            }
            return false
        }
        let gone = existing.filter { !seenPaths.contains($0.key) && isGone($0.key) }.map(\.value)
        if !gone.isEmpty {
            var touched = Set<PersistentIdentifier>()
            for file in gone {
                droppedKeys.append(SyncKeys.file(sourceID: sourceID, relativePath: file.relativePath))
                if let item = file.item { touched.insert(item.persistentModelID) }
                modelContext.delete(file)
            }
            try modelContext.save()
            var retired = 0
            for id in touched {
                guard let item = modelContext.model(for: id) as? MediaItem, !item.isDeleted, item.files.isEmpty, item.kind != .show, item.kind != .audiobook else { continue }
                item.pendingDeletion = true; item.hidden = true
                droppedKeys.append(SyncKeys.item(item.itemKey))
                retired += 1
                if let show = item.show, show.episodes.allSatisfy({ $0.pendingDeletion || $0.files.isEmpty }) {
                    show.pendingDeletion = true; show.hidden = true
                    droppedKeys.append(SyncKeys.item(show.itemKey))
                }
            }
            try modelContext.save()
            Diagnostics.log("scan", "\(record.name): \(gone.count) files gone from the share, \(retired) titles retired")
        }
        try modelContext.save()
        await source.disconnect()

        report.phase = .classifying
        progress?(report)
        // Every unreviewed review file is re-parsed on each scan: it is local and cheap, and it means a parser
        // improvement reaches files an older build gave up on, instead of retrying stale guesses.
        let pending = record.files.filter { ($0.classificationRaw == "pending" || ($0.classificationRaw == "review" && !$0.reviewed)) && !$0.ignored }
        for file in pending {
            apply(Classifier.classify(relativePath: file.relativePath, folderTag: record.tag(for: file.relativePath)), to: file)
        }
        try modelContext.save()

        if let tmdb = providers.tmdb {
            report.phase = .matching
            progress?(report)
            let matcher = Matcher(context: modelContext, tmdb: tmdb, providers: providers)
            // Review files are tried too when the classifier had a guess; the matcher only accepts a sure hit for them.
            func inScope(_ path: String) -> Bool { scope.map { $0.isEmpty || path.hasPrefix($0 + "/") } ?? true }
            // Reviewed files without an item are tried again too: the viewer has said what they are.
            // A placeholder does not count as matched: TMDb is asked again each scan (answers are cached),
            // so a title it learns later, or a search that has since got more forgiving, takes over.
            let toMatch = record.files.filter { file in inScope(file.relativePath) && !file.ignored && file.classificationRaw != "audio" && file.classificationRaw != "browsed"
                && (file.item == nil || file.item?.itemKey.hasPrefix("local-") == true)
                && (file.reviewed || file.classificationRaw != "review" || file.guessKindRaw != nil) }
            report.matchTotal = toMatch.count
            progress?(report)
            var reasons: [String] = []
            var consecutiveFailures = 0, pauses = 0
            for file in toMatch {
                try Task.checkCancellation()
                var outcome = await matcher.match(file)
                // A lookup that failed on the network gets one more go a couple of seconds later: most
                // blips are that short, and it saves the file waiting for the next pass.
                if case .skipped(let reason) = outcome, reason != nil {
                    try await Task.sleep(for: .seconds(2))
                    outcome = await matcher.match(file)
                    if case .skipped = outcome {} else { Diagnostics.log("scan", "\(record.name): \(file.fileName.prefix(60)) matched on the second try") }
                }
                switch outcome {
                case .matched: report.matched += 1; consecutiveFailures = 0
                case .review: report.needsReview += 1; consecutiveFailures = 0
                case .skipped(let reason):
                    report.skipped += 1
                    if let reason {
                        report.lastError = reason
                        if !reasons.contains(reason), reasons.count < 3 {
                            reasons.append(reason)
                            Diagnostics.log("scan", "\(record.name): \(file.fileName.prefix(60)) skipped: \(reason)")
                        }
                        consecutiveFailures += 1
                    }
                }
                // A burst of failures is the network, not the files: wait for it to come back rather
                // than burn through every title with the same error, and give up this pass if it doesn't.
                if consecutiveFailures >= 5 {
                    guard pauses < 3 else {
                        Diagnostics.log("scan", "\(record.name): matching stopped after repeated failures; \(toMatch.count - report.matchDone) files wait for the next pass")
                        break
                    }
                    pauses += 1; consecutiveFailures = 0
                    Diagnostics.log("scan", "\(record.name): \(report.skipped) lookups failed, pausing 10s (\(report.lastError ?? ""))")
                    progress?(report)
                    try await Task.sleep(for: .seconds(10))
                }
                if report.matchDone % 10 == 0 { progress?(report); try modelContext.save() }
            }
            Diagnostics.log("scan", "\(record.name): matched \(report.matched), review \(report.needsReview), skipped \(report.skipped) of \(toMatch.count)\(report.lastError.map { " · last error: \($0)" } ?? "")")
        } else {
            Diagnostics.log("scan", "\(record.name): no TMDb client, matching skipped")
        }
        report.needsReview += record.files.filter(\.needsReview).count
        record.status = .online
        record.lastScan = Date()
        try modelContext.save()
        report.phase = .done
        progress?(report)
        return droppedKeys
    }

    /// Book items and their parts for the grouped audio files. Keys come from the source and the
    /// book's path, so a rescan finds the same items; a book whose title or author the tags have
    /// already given keeps them, the names only fill what is still empty. Returns how many books are new.
    private func upsertBooks(_ books: [AudiobookGrouper.Book], record: SourceRecord) -> Int {
        let filesByPath = Dictionary(record.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        var new = 0
        for b in books {
            let key = ItemKey.book(sourceID: record.id, path: b.path)
            let book: MediaItem
            if let found = try? modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first {
                book = found
                if !book.tagsRead { book.title = b.title; book.sortTitle = MediaItem.makeSortTitle(b.title); book.author = b.author ?? book.author }
                if book.pendingDeletion || book.hidden { book.pendingDeletion = false; book.hidden = false }
            } else {
                book = MediaItem(itemKey: key, kind: .audiobook, title: b.title, year: b.year, confidence: .manual)
                book.author = b.author
                modelContext.insert(book)
                new += 1
            }
            // Tags trump names: once read, the names only fill what the tags left empty.
            if !book.tagsRead || book.seriesName == nil { book.seriesName = b.series ?? book.seriesName; book.seriesIndex = b.seriesIndex ?? book.seriesIndex }
            if book.year == nil { book.year = b.year }
            book.pendingSync = true; book.updatedAt = Date()
            for (i, part) in b.parts.enumerated() {
                let partKey = ItemKey.bookPart(bookKey: key, index: i + 1)
                let item: MediaItem
                if let found = try? modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == partKey })).first { item = found }
                else { item = MediaItem(itemKey: partKey, kind: .episode, title: part.title, confidence: .manual); modelContext.insert(item) }
                item.title = part.title; item.sortTitle = MediaItem.makeSortTitle(part.title)
                item.seasonNumber = 1; item.episodeNumber = i + 1
                item.show = book
                if item.pendingDeletion || item.hidden { item.pendingDeletion = false; item.hidden = false }
                item.pendingSync = true; item.updatedAt = Date()
                if let file = filesByPath[part.relativePath], file.item !== item { file.item = item; file.pendingSync = true; file.updatedAt = Date() }
            }
            // Parts the book no longer has (files renamed, halves merged differently) go quietly.
            let keep = Set(b.parts.indices.map { ItemKey.bookPart(bookKey: key, index: $0 + 1) })
            for stale in book.episodes where !keep.contains(stale.itemKey) && stale.files.isEmpty { stale.pendingDeletion = true; stale.hidden = true }
        }
        return new
    }

    private func apply(_ c: Classification, to file: MediaFile) {
        // Only a real change marks the row for sync: re-parsing a review file on every scan must not
        // stamp it "newer" than a decision taken on another device.
        func snapshot() -> String { [file.classificationRaw, file.guessTitle ?? "", "\(file.guessYear ?? -1)", "\(file.guessSeason ?? -1)", "\(file.guessEpisode ?? -1)", file.guessKindRaw ?? "", "\(file.ignored)"].joined(separator: "\u{1F}") }
        let before = snapshot()
        defer { if snapshot() != before { file.pendingSync = true; file.updatedAt = Date() } }
        switch c {
        case .episode(let p):
            file.classificationRaw = "episode"; file.guessKindRaw = nil; fill(file, p)
        case .film(let p):
            file.classificationRaw = "film"; file.guessKindRaw = nil; fill(file, p)
        case .needsReview(let p, let guess):
            file.classificationRaw = "review"; fill(file, p)
            file.guessKindRaw = guess?.rawValue
            if guess == nil { file.guessTitle = p.title.isEmpty ? nil : p.title }
        case .ignore:
            file.ignored = true; file.classificationRaw = "ignored"
        }
    }

    private func fill(_ file: MediaFile, _ p: ParsedName) {
        file.guessTitle = p.title
        file.guessYear = p.year
        file.guessSeason = p.season
        file.guessEpisode = p.episode
        file.qualityTags = p.quality
        file.resolution = p.quality.first { $0.hasSuffix("p") }
    }

    private func fetchSource(_ id: UUID) throws -> SourceRecord? {
        var d = FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }
}
#endif

private extension String { func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self } }
