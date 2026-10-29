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
        XCTAssertEqual(d.confidence, .autoHigh, "one letter off, right year, nothing close behind: that is the film")
    }
}

/// The films Paul had to confirm by hand on 29 Oct, replayed from TMDb's answers of that day.
final class HandConfirmedFilmsTests: XCTestCase {
    private func movie(_ id: Int, _ title: String, _ year: String, pop: Double) -> TMDbMovieSummary {
        try! JSONDecoder().decode(TMDbMovieSummary.self, from: Data(#"{"id": \#(id), "title": "\#(title)", "release_date": "\#(year)", "popularity": \#(pop)}"#.utf8))
    }

    func testTheFamousOneAmongSameNamedFilmsOfTheSameYear() {
        let aladdin = MatchScorer.decideMovie([movie(812, "Aladdin", "1992-11-25", pop: 20.7), movie(343693, "Aladdin", "1992-01-01", pop: 1.4), movie(357528, "Aladdin", "1992-01-01", pop: 4.1)], parsed: ParsedName(title: "Aladdin", year: 1992))
        XCTAssertEqual(aladdin.pick?.id, 812); XCTAssertEqual(aladdin.confidence, .autoHigh)
        let sing = MatchScorer.decideMovie([movie(335797, "Sing", "2016-11-23", pop: 21.4), movie(369557, "Sing Street", "2016-03-11", pop: 4.9), movie(427416, "Sing", "2016-02-05", pop: 1.1)], parsed: ParsedName(title: "Sing", year: 2016))
        XCTAssertEqual(sing.pick?.id, 335797); XCTAssertEqual(sing.confidence, .autoHigh)
    }

    func testTwoObscuritiesOfTheSameNameAndYearStayLow() {
        let d = MatchScorer.decideMovie([movie(1, "Echo", "2010-01-01", pop: 2.0), movie(2, "Echo", "2010-06-01", pop: 1.5)], parsed: ParsedName(title: "Echo", year: 2010))
        XCTAssertEqual(d.confidence, .autoLow)
    }

    func testSameTitleAYearOffDoesNotHoldBackTheExactOne() {
        let d = MatchScorer.decideMovie([movie(77950, "Turbo", "2013-07-11", pop: 9.0), movie(724586, "Turbo", "2012-01-01", pop: 0.8), movie(539707, "Lakewood Plaza Turbo", "2013-01-01", pop: 1.8)], parsed: ParsedName(title: "Turbo", year: 2013))
        XCTAssertEqual(d.pick?.id, 77950); XCTAssertEqual(d.confidence, .autoHigh)
        let beauty = MatchScorer.decideMovie([movie(321612, "Beauty and the Beast", "2017-03-16", pop: 19.4), movie(197796, "Beauty and the Beast", "2014-02-12", pop: 9.4), movie(1729291, "The Beauty and the Beast", "2017-01-01", pop: 0.4)], parsed: ParsedName(title: "Beauty and the Beast", year: 2017))
        XCTAssertEqual(beauty.pick?.id, 321612); XCTAssertEqual(beauty.confidence, .autoHigh)
    }

    func testSpacingInsideAWordIsStillTheSameTitle() {
        let d = MatchScorer.decideMovie([movie(396330, "LEGO DC Comics Super Heroes: Justice League - Gotham City Breakout", "2016-06-21", pop: 5), movie(382512, "LEGO DC Comics Super Heroes: Justice League - Cosmic Clash", "2016-02-09", pop: 5)], parsed: ParsedName(title: "Lego DC Comics Superheroes Justice League Gotham City Breakout", year: 2016))
        XCTAssertEqual(d.pick?.id, 396330); XCTAssertEqual(d.confidence, .autoHigh)
    }

    func testFranchisePrefixOnTheFileName() {
        let loaf = MatchScorer.decideMovie([movie(14447, "A Matter of Loaf and Death", "2008-12-25", pop: 3)], parsed: ParsedName(title: "Wallace and Gromit A Matter of Loaf and Death", year: 2008), yearFiltered: true)
        XCTAssertEqual(loaf.pick?.id, 14447); XCTAssertEqual(loaf.confidence, .autoHigh)
        let shave = MatchScorer.decideMovie([movie(532, "A Close Shave", "1996-01-01", pop: 3.5)], parsed: ParsedName(title: "Wallace and Gromit A Close Shave", year: 1995), yearFiltered: true)
        XCTAssertEqual(shave.pick?.id, 532); XCTAssertNotEqual(shave.confidence, .unmatched)
        XCTAssertFalse(MatchScorer.contained("up", in: "wallace and gromit up"), "a one-word title is not evidence")
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
