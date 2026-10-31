import XCTest
import SwiftData
import MediaCore
import Metadata
import MediaSources
@testable import Library

/// The store against an in-memory container: the rules that decide what the library shows.
@MainActor
final class LibraryStoreTests: XCTestCase {
    private var store: LibraryStore!
    private var source: SourceRecord!

    override func setUp() async throws {
        store = LibraryStore(container: try LibrarySchema.container(inMemory: true))
        source = SourceRecord(config: SourceConfig(id: UUID(), name: "NAS", type: .smb, host: "nas", port: 445, path: "", useTLS: false, username: nil, macAddress: nil))
        store.context.insert(source)
        try store.context.save()
    }

    @discardableResult
    private func file(_ path: String, item: MediaItem? = nil, classification: String = "film") -> MediaFile {
        let f = MediaFile(relativePath: path, size: 1000, modified: nil, source: source)
        f.classificationRaw = classification
        f.item = item
        store.context.insert(f)
        return f
    }
    @discardableResult
    private func item(_ key: String, _ kind: MediaKind, _ title: String, confidence: MatchConfidence = .autoHigh) -> MediaItem {
        let i = MediaItem(itemKey: key, kind: kind, title: title, confidence: confidence)
        store.context.insert(i)
        return i
    }
    /// A book with one part and a file, as the scanner makes them.
    private func book(_ title: String, author: String?, series: String? = nil, index: Int? = nil, tagsRead: Bool = true) -> MediaItem {
        let b = item(ItemKey.book(sourceID: source.id, path: title), .audiobook, title, confidence: .manual)
        b.author = author; b.seriesName = series; b.seriesIndex = index; b.tagsRead = tagsRead
        let part = item(ItemKey.bookPart(bookKey: b.itemKey, index: 1), .episode, title, confidence: .manual)
        part.show = b; part.seasonNumber = 1; part.episodeNumber = 1
        file("Books/\(title).m4b", item: part, classification: "audio")
        return b
    }

    func testSetTagDedupesAndExcludedFoldersLeaveTheScan() throws {
        try store.setTag(.tv, folder: "Shows", on: source)
        try store.setTag(.audiobooks, folder: "Shows", on: source)
        XCTAssertEqual(source.folderRules.filter { $0.folderPath == "Shows" }.count, 1, "one rule per folder, retagged in place")
        XCTAssertEqual(source.tag(for: "Shows/Bluey/S01E01.mkv"), .audiobooks)
        try store.setTag(.excluded, folder: "Shows/Extras", on: source)
        XCTAssertFalse(source.rule(for: "Shows/Extras/x.mkv")!.includeInScan)
        XCTAssertEqual(source.audiobooksRoot(for: "Shows/Bluey/a.m4b"), "Shows")
        XCTAssertNil(source.audiobooksRoot(for: "Films/a.m4b"))
    }

    func testDedupeFolderRulesRemovesTheExtras() throws {
        for _ in 0..<3 { let r = FolderRule(folderPath: "Audio Books", tag: .audiobooks); r.source = source; source.folderRules.append(r) }
        try store.context.save()
        store.dedupeFolderRules()
        XCTAssertEqual(source.folderRules.filter { $0.folderPath == "Audio Books" }.count, 1)
    }

    func testNeedsReviewHoldsUnmatchedFilesEvenAfterADecision() throws {
        let waiting = file("Torrents/odd.mkv", classification: "review")
        let decided = file("Torrents/odd2.mkv", classification: "review"); decided.reviewed = true
        let placeholder = item(ItemKey.localFilm(title: "odd3", year: nil), .film, "odd3", confidence: .unmatched)
        let stillUnmatched = file("Torrents/odd3.mkv", item: placeholder, classification: "review"); stillUnmatched.reviewed = true
        let matched = item("movie:1", .film, "Up")
        let settled = file("Torrents/up.mkv", item: matched, classification: "review"); settled.reviewed = true
        let ignored = file("Torrents/junk.mkv", classification: "review"); ignored.ignored = true
        try store.context.save()
        let paths = Set(store.filesNeedingReview().map(\.relativePath))
        XCTAssertEqual(paths, ["Torrents/odd.mkv", "Torrents/odd2.mkv", "Torrents/odd3.mkv"])
        _ = waiting
    }

    func testSearchReachesAuthorsSeriesNarratorsAndEpisodeTitles() throws {
        book("Remnant Population", author: "Elizabeth Moon").narrator = "Suzanne Toren"
        book("Trading in Danger", author: "Elizabeth Moon", series: "Vatta's War", index: 1)
        let show = item("show:2290", .show, "Stargate Atlantis")
        let ep = item("show:2290:S05E15", .episode, "Remnants"); ep.show = show; ep.seasonNumber = 5; ep.episodeNumber = 15
        file("TV/SGA/S05E15.mkv", item: ep, classification: "episode")
        try store.context.save()
        XCTAssertEqual(Set(store.search("Moon").map(\.title)), ["Remnant Population", "Trading in Danger"])
        XCTAssertEqual(store.search("Vatta").map(\.title), ["Trading in Danger"])
        XCTAssertEqual(store.search("Toren").map(\.title), ["Remnant Population"])
        let remnants = store.search("Remnant").map(\.title)
        XCTAssertEqual(remnants, ["Remnant Population", "Remnants"], "the book first, then the episode that matched by name")
        XCTAssertTrue(store.search("Part").isEmpty, "a book's parts are not results of their own")
    }

    func testRecentlyAddedIncludesBooksWithFiles() throws {
        let film = item("movie:1", .film, "Up"); file("Films/Up.mkv", item: film)
        book("Snuff", author: "Terry Pratchett")
        let empty = item(ItemKey.book(sourceID: source.id, path: "Nothing"), .audiobook, "Nothing", confidence: .manual)
        try store.context.save()
        let titles = Set(store.recentlyAdded().map(\.title))
        XCTAssertEqual(titles, ["Up", "Snuff"])
        _ = empty
    }

    func testCatalogueLookupRespectsTagsUnlessChosenByHand() throws {
        let b = book("Trading in Danger", author: "Elizabeth Moon", series: "Vatta's War", index: 1)
        var hit = AudiobookHit(source: "Audible", asin: "B1", title: "Trading in Danger: A Vatta's War Novel", authors: ["Elizabeth Moon"], narrators: ["Cynthia Holloway"], year: 2007, summary: "Ky Vatta…", coverURL: "https://x/1.jpg")
        hit.allSeries = [.init(name: "Vatta Universe", position: "1")]; hit.chooseSeries(known: [])
        store.applyBookLookup(b, hit: hit, manual: false)
        XCTAssertEqual(b.title, "Trading in Danger", "the tags' title stands on an automatic match")
        XCTAssertEqual(b.seriesName, "Vatta's War", "and so does their series")
        XCTAssertEqual(b.narrator, "Cynthia Holloway"); XCTAssertEqual(b.overview, "Ky Vatta…"); XCTAssertEqual(b.posterOverrideURL, "https://x/1.jpg")
        XCTAssertEqual(b.asin, "B1"); XCTAssertEqual(b.bookLookup, "matched")
        store.applyBookLookup(b, hit: hit, manual: true)
        XCTAssertEqual(b.title, "Trading in Danger: A Vatta's War Novel", "chosen by hand, the edition's details replace the book's")
        XCTAssertEqual(b.seriesName, "Vatta Universe"); XCTAssertEqual(b.bookLookup, "manual")
    }

    func testCatalogueSeriesFollowsTheAuthorsOtherBooks() throws {
        book("Guards! Guards!", author: "Terry Pratchett", series: "Discworld", index: 8)
        let thud = book("Thud!", author: "Terry Pratchett", series: nil)
        var hit = AudiobookHit(source: "Audible", asin: "B2", title: "Thud!", authors: ["Terry Pratchett"])
        hit.allSeries = [.init(name: "Discworld: Ankh-Morpork City Watch", position: "7"), .init(name: "Discworld", position: "34")]
        hit.chooseSeries(known: [])
        store.applyBookLookup(thud, hit: hit, manual: false)
        XCTAssertEqual(thud.seriesName, "Discworld"); XCTAssertEqual(thud.seriesIndex, 34)
    }

    func testAFolderNamedForTheAuthorIsNotASeries() throws {
        // The folder parser files "Books/Terry Pratchett/Mort.m4b" under a series "Terry Pratchett".
        let mort = book("Mort", author: nil, series: "Terry Pratchett")
        store.applyBookTags(mort, title: "Mort", author: "Terry Pratchett", narrator: nil, year: nil, cover: nil)
        XCTAssertNil(mort.seriesName, "the tags name the author, so the folder was not a series")
        var hit = AudiobookHit(source: "Audible", asin: "B3", title: "Mort", authors: ["Terry Pratchett"])
        hit.allSeries = [.init(name: "Discworld", position: "4")]; hit.chooseSeries(known: [])
        store.applyBookLookup(mort, hit: hit, manual: false)
        XCTAssertEqual(mort.seriesName, "Discworld"); XCTAssertEqual(mort.seriesIndex, 4)
    }

    func testSmartCollectionsAreCollectionsWithRulesKeptApart() throws {
        store.addCollection(named: "Marvel")
        let id = UUID()
        store.saveSmartCollection(id: id, name: "Unwatched films", rules: #"{"kind":"films"}"#)
        XCTAssertEqual(store.collections().map(\.name), ["Marvel"])
        XCTAssertEqual(store.smartCollections().map(\.name), ["Unwatched films"])
        store.saveSmartCollection(id: id, name: "Unwatched", rules: #"{"kind":"any"}"#)
        XCTAssertEqual(store.smartCollections().count, 1); XCTAssertEqual(store.smartCollections().first?.name, "Unwatched")
        store.removeCollection(id: id)
        XCTAssertTrue(store.smartCollections().isEmpty)
        XCTAssertEqual(store.collections().count, 1)
    }

    func testFilesNeedingProbeSkipBrowsedAndUnmatched() throws {
        let film = item("movie:1", .film, "Up")
        file("Films/Up.mkv", item: film)
        let probed = file("Films/Up2.mkv", item: film); probed.duration = 100; probed.videoCodec = "HEVC"
        file("Torrents/x.mp3", classification: "browsed")
        file("Torrents/loose.mkv")
        try store.context.save()
        XCTAssertEqual(store.filesNeedingProbe().map(\.relativePath), ["Films/Up.mkv"])
        store.recordProbe(store.filesNeedingProbe()[0], videoCodec: "H.264", audio: "AAC 2.0", subtitles: nil, duration: 5400, resolution: "1080p")
        XCTAssertTrue(store.filesNeedingProbe().isEmpty)
        XCTAssertEqual(film.files.first { $0.relativePath == "Films/Up.mkv" }?.resolution, "1080p")
    }
}
