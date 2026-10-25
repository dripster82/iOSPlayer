import XCTest
import MediaCore
@testable import Metadata

final class ForgivingSearchTests: XCTestCase {
    private func movie(_ id: Int, _ title: String, _ year: String, pop: Double) -> TMDbMovieSummary {
        try! JSONDecoder().decode(TMDbMovieSummary.self, from: Data(#"{"id": \#(id), "title": "\#(title)", "release_date": "\#(year)", "popularity": \#(pop)}"#.utf8))
    }

    func testQueryOrder() {
        XCTAssertEqual(TMDbClient.queries(for: "Teeage Mutant Ninja Turtles"),
                       ["Teeage Mutant Ninja Turtles", "Teeage Mutant Ninja", "Teeage Mutant", "Mutant Ninja Turtles", "Ninja Turtles"])
        XCTAssertEqual(TMDbClient.queries(for: "South Park"), ["South Park"])
        XCTAssertEqual(TMDbClient.queries(for: "Coco"), ["Coco"])
    }

    func testTypoInTheFirstWordStillScoresTheRightFilm() {
        let results = [
            movie(1498, "Teenage Mutant Ninja Turtles", "1990-03-30", pop: 40),
            movie(2, "Teenage Mutant Ninja Turtles: Cowabunga, Shredhead", "1990-01-01", pop: 2),
        ]
        let d = MatchScorer.decideMovie(results, parsed: ParsedName(title: "Teeage Mutant Ninja Turtles", year: 1990))
        XCTAssertEqual(d.pick?.id, 1498)
        XCTAssertEqual(d.confidence, .autoLow, "a near-miss title with the right year is a low-confidence match, not a blank")
    }
}

final class LoneAnswerTests: XCTestCase {
    private func movie(_ id: Int, _ title: String, _ year: String, pop: Double) -> TMDbMovieSummary {
        try! JSONDecoder().decode(TMDbMovieSummary.self, from: Data(#"{"id": \#(id), "title": "\#(title)", "release_date": "\#(year)", "popularity": \#(pop)}"#.utf8))
    }
    func testTMDbsOnlyAnswerFromTheRightYearIsTaken() {
        let d = MatchScorer.decideMovie([movie(7, "South Park: Post COVID: The Return of COVID", "2021-12-16", pop: 3)], parsed: ParsedName(title: "South Park Post Covid Covid Returns", year: 2021))
        XCTAssertEqual(d.pick?.id, 7)
        XCTAssertNotEqual(d.confidence, .unmatched)
        let grand = MatchScorer.decideMovie([movie(8, "A Grand Day Out", "1990-05-18", pop: 5)], parsed: ParsedName(title: "A Grand Day Out with Wallace and Gromit", year: 1989))
        XCTAssertEqual(grand.pick?.id, 8)
        XCTAssertNotEqual(grand.confidence, .unmatched)
        // The same film filed under its 1994 re-release year, found by a year-filtered search.
        let reissue = MatchScorer.decideMovie([movie(8, "A Grand Day Out", "1990-05-18", pop: 5)], parsed: ParsedName(title: "A Grand Day Out", year: 1994), yearFiltered: true)
        XCTAssertEqual(reissue.pick?.id, 8)
    }
    func testAWrongLoneAnswerIsStillRefused() {
        let d = MatchScorer.decideMovie([movie(9, "Completely Different Film", "2005-01-01", pop: 3)], parsed: ParsedName(title: "South Park Post Covid", year: 2021))
        XCTAssertNil(d.pick)
    }
}
