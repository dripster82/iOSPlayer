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
    public enum Phase: String, Sendable { case connecting, listing, classifying, matching, done, failed }
}

/// Walks a source, upserts `MediaFile`s, classifies them, and hands matchable ones to `Matcher`.
/// One source at a time, breadth-first, incremental by (path, size, modified). PLAN.md §11.3.
@ModelActor
public actor LibraryScanner {

    public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    public func scan(sourceID: UUID, credentials: Credentials?, tmdb: TMDbClient?, progress: ProgressHandler? = nil) async throws {
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
        let roots = record.folderRules.filter(\.includeInScan).map(\.folderPath)
        var queue = roots.isEmpty ? [""] : roots
        var seenPaths = Set<String>()
        let existing = Dictionary(record.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        report.phase = .listing

        while !queue.isEmpty {
            try Task.checkCancellation()
            let dir = queue.removeFirst()
            if let tag = record.tag(for: dir), tag == .excluded { continue }
            let entries: [DirectoryEntry]
            do { entries = try await source.list(dir) } catch { continue } // one bad folder shouldn't kill the scan

            let videos = entries.filter { !$0.isDirectory && $0.isVideo }
            let subs = entries.filter { !$0.isDirectory && $0.isSubtitle }
            for e in entries where e.isDirectory && !e.name.hasPrefix(".") && !e.name.hasPrefix("@") { queue.append(e.relativePath) }

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
                    }
                } else {
                    let file = MediaFile(relativePath: v.relativePath, size: v.size ?? 0, modified: v.modified, source: record)
                    file.sidecars = sidecars
                    modelContext.insert(file)
                    report.filesNew += 1
                }
            }
            if report.filesSeen % 50 == 0 { progress?(report); try modelContext.save() }
        }

        // Files that vanished keep their records (the share may just be offline); mark the time instead.
        try modelContext.save()
        await source.disconnect()

        report.phase = .classifying
        progress?(report)
        let pending = record.files.filter { $0.classificationRaw == "pending" && !$0.ignored }
        for file in pending {
            apply(Classifier.classify(relativePath: file.relativePath, folderTag: record.tag(for: file.relativePath)), to: file)
        }
        try modelContext.save()

        if let tmdb {
            report.phase = .matching
            progress?(report)
            let matcher = Matcher(context: modelContext, tmdb: tmdb)
            for file in record.files where file.item == nil && !file.ignored && file.classificationRaw != "review" {
                try Task.checkCancellation()
                let outcome = await matcher.match(file)
                switch outcome {
                case .matched: report.matched += 1
                case .review: report.needsReview += 1
                case .skipped: break
                }
                if (report.matched + report.needsReview) % 10 == 0 { progress?(report); try modelContext.save() }
            }
        }
        report.needsReview += record.files.filter(\.needsReview).count
        record.status = .online
        record.lastScan = Date()
        try modelContext.save()
        report.phase = .done
        progress?(report)
    }

    private func apply(_ c: Classification, to file: MediaFile) {
        switch c {
        case .episode(let p):
            file.classificationRaw = "episode"; fill(file, p)
        case .film(let p):
            file.classificationRaw = "film"; fill(file, p)
        case .needsReview(let p, let guess):
            file.classificationRaw = "review"; fill(file, p)
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
