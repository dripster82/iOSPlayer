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
}
