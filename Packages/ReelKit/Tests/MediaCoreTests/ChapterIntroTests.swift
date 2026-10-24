import XCTest
@testable import MediaCore

final class ChapterIntroTests: XCTestCase {
    private func ch(_ i: Int, _ title: String, _ start: TimeInterval, _ duration: TimeInterval) -> Chapter {
        Chapter(id: i, title: title, start: start, duration: duration)
    }

    func testNamedIntroMatchesWholeWordsOnly() {
        XCTAssertTrue(ch(0, "Intro", 0, 60).looksLikeIntro)
        XCTAssertTrue(ch(1, "Opening Credits", 30, 80).looksLikeIntro)
        XCTAssertTrue(ch(1, "OP", 90, 90).looksLikeIntro)
        XCTAssertTrue(ch(1, "Cold Open", 0, 120).looksLikeIntro)
        XCTAssertFalse(ch(1, "The Shop", 60, 300).looksLikeIntro, "'op' inside 'shop' is not an opening")
        XCTAssertFalse(ch(1, "Introduction of the Suspects", 60, 300).looksLikeIntro)
        XCTAssertFalse(ch(1, "Opening", 900, 60).looksLikeIntro, "too late in the file")
        XCTAssertFalse(ch(1, "Chapter 2", 60, 90).looksLikeIntro)
    }

    func testGenericTitles() {
        XCTAssertTrue(ch(0, "Chapter 1", 0, 1).hasGenericTitle)
        XCTAssertTrue(ch(0, "Track 12", 0, 1).hasGenericTitle)
        XCTAssertTrue(ch(0, "", 0, 1).hasGenericTitle)
        XCTAssertTrue(ch(0, "3", 0, 1).hasGenericTitle)
        XCTAssertFalse(ch(0, "Chapter One: The Boy", 0, 1).hasGenericTitle)
        XCTAssertFalse(ch(0, "Opening", 0, 1).hasGenericTitle)
    }

    func testUnnamedEpisodeShapeFallsBackToShortEarlyChapter() {
        let episode = [ch(0, "Chapter 1", 0, 150), ch(1, "Chapter 2", 150, 75), ch(2, "Chapter 3", 225, 1200), ch(3, "Chapter 4", 1425, 900)]
        XCTAssertEqual(episode.intro?.id, 1)
    }

    func testLongColdOpenIsNotMistakenForTheTitles() {
        // Stargate Atlantis S01E15 as cut on the BluRay: 118 s cold open, 61 s titles, story, 35 s ending.
        let e15 = [ch(0, "Chapter 01", 0, 118), ch(1, "Chapter 02", 118, 61), ch(2, "Chapter 03", 179, 2404), ch(3, "Chapter 04", 2583, 35)]
        XCTAssertEqual(e15.intro?.id, 1)
    }

    func testTitlesFirstWhenNothingPrecedesThem() {
        let e = [ch(0, "Chapter 1", 0, 60), ch(1, "Chapter 2", 60, 1500), ch(2, "Chapter 3", 1560, 300)]
        XCTAssertEqual(e.intro?.id, 0)
    }

    func testFilmWithLongUnnamedChaptersHasNoIntro() {
        let film = [ch(0, "Chapter 1", 0, 600), ch(1, "Chapter 2", 600, 900), ch(2, "Chapter 3", 1500, 1200)]
        XCTAssertNil(film.intro)
    }

    func testNamedChaptersNeverUseShapeFallback() {
        let mixed = [ch(0, "Arrival", 0, 60), ch(1, "The Letter", 60, 60), ch(2, "Dinner", 120, 1200)]
        XCTAssertNil(mixed.intro, "short but named chapters are story, not an intro")
    }

    func testLastChapterIsNeverTheIntro() {
        let two = [ch(0, "Chapter 1", 0, 60), ch(1, "Chapter 2", 60, 60), ch(2, "Chapter 3", 120, 60)]
        XCTAssertEqual(two.intro?.id, 1, "a title-length chapter after a cold open beats the first chapter")
    }
}
