import XCTest
@testable import MediaCore

final class ClassifierTests: XCTestCase {

    func testEpisodeInTVFolder() {
        guard case .episode(let p) = Classifier.classify(relativePath: "TV/Harbour Lights/Season 2/Harbour.Lights.S02E05.mkv", folderTag: nil) else { return XCTFail() }
        XCTAssertEqual(p.title, "Harbour Lights")
    }

    func testFilmWithYear() {
        guard case .film(let p) = Classifier.classify(relativePath: "Films/Tideline (2018).mkv", folderTag: nil) else { return XCTFail() }
        XCTAssertEqual(p.year, 2018)
    }

    func testAmbiguousGoesToReview() {
        guard case .needsReview(_, let guess) = Classifier.classify(relativePath: "Kids/allotment_ep5_final_FINAL.mkv", folderTag: nil) else { return XCTFail() }
        XCTAssertNotEqual(guess, .show)
    }

    func testFolderTagFilmsOverridesMissingYear() {
        guard case .film = Classifier.classify(relativePath: "Movies/Grain.mkv", folderTag: .films) else { return XCTFail() }
    }

    func testEpisodeInsideFilmsFolderIsReviewed() {
        guard case .needsReview(_, let guess) = Classifier.classify(relativePath: "Movies/Something.S01E01.mkv", folderTag: .films) else { return XCTFail() }
        XCTAssertEqual(guess, .episode)
    }

    func testExcludedAndSamples() {
        XCTAssertEqual(Classifier.classify(relativePath: "Home Videos/x.mov", folderTag: .excluded), .ignore)
        XCTAssertEqual(Classifier.classify(relativePath: "Films/Film (2019)/sample.mkv", folderTag: nil), .ignore)
        XCTAssertEqual(Classifier.classify(relativePath: "Films/Film (2019)/Extras/deleted.mkv", folderTag: nil), .ignore)
    }

    func testBlurayDiscStructureIsIgnored() {
        XCTAssertEqual(Classifier.classify(relativePath: "Torrents/2 Sort/[BDMV] Danmachi S2/Danmachi S2 BD-1/BDMV/STREAM/00002.m2ts", folderTag: nil), .ignore)
    }

    func testFansubDashEpisodeIsEpisodeWithoutFolderHints() {
        let c = Classifier.classify(relativePath: "Torrents/2 Sort/Tokyo Underground/(Hi10)_Tokyo_Underground_-_01_(480p).mkv", folderTag: nil)
        guard case .episode(let p) = c else { return XCTFail("expected episode, got \(c)") }
        XCTAssertEqual(p.title, "Tokyo Underground")
    }

    func testCreditlessOpeningsAndEndingsAreIgnored() {
        XCTAssertEqual(Classifier.classify(relativePath: "Torrents/2 Sort/Sword Art Online/Sword Art Online Season 02 (2014)/Extra/[A&C] Sword Art Online S02OP02v2 [BDRip 1080p] [7696C1AE].mkv", folderTag: nil), .ignore)
        XCTAssertEqual(Classifier.classify(relativePath: "Torrents/2 Sort/Tokyo Underground/(Hi10)_Tokyo_Underground_-_NCED_(480p)_(V-A).mkv", folderTag: nil), .ignore)
    }
}
