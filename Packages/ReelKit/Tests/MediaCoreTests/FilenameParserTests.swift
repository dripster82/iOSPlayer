import XCTest
@testable import MediaCore

final class FilenameParserTests: XCTestCase {

    private func p(_ path: String) -> ParsedName { FilenameParser.parse(relativePath: path) }

    func testSceneStyleEpisode() {
        let r = p("TV/Harbour.Lights.S02E05.1080p.WEB-DL.x265-GRP.mkv")
        XCTAssertEqual(r.title, "Harbour Lights")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 5)
        XCTAssertTrue(r.quality.contains("1080p"))
        XCTAssertTrue(r.quality.contains("x265"))
    }

    func testSeasonFolderWithBareNumber() {
        let r = p("TV/Harbour Lights/Season 2/05 - Quiet Hours.mkv")
        XCTAssertEqual(r.title, "Harbour Lights")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 5)
    }

    func testShowFolderWithYearAndXFormat() {
        let r = p("Series/Orbital (2019)/Season 1/Orbital 1x03 Interference.mkv")
        XCTAssertEqual(r.title, "Orbital")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 3)
    }

    func testDoubleEpisode() {
        let r = p("Cold Ledger S01E01E02 Pilot.mkv")
        XCTAssertEqual(r.episode, 1)
        XCTAssertEqual(r.episodeEnd, 2)
    }

    func testFilmWithParenYear() {
        let r = p("Films/The Last Projectionist (2019).mkv")
        XCTAssertEqual(r.title, "The Last Projectionist")
        XCTAssertEqual(r.year, 2019)
        XCTAssertNil(r.season)
    }

    func testFilmSceneStyle() {
        let r = p("Movies/Mountain.Debt.2022.2160p.UHD.BluRay.x265.HDR.Atmos-GROUP.mkv")
        XCTAssertEqual(r.title, "Mountain Debt")
        XCTAssertEqual(r.year, 2022)
        XCTAssertTrue(r.quality.contains("2160p"))
        XCTAssertTrue(r.quality.contains("hdr"))
    }

    func testFilmInOwnFolderWithNoisyFile() {
        let r = p("Films/Null Island (2024)/null.island.2024.2160p.dv.mkv")
        XCTAssertEqual(r.title, "Null Island")
        XCTAssertEqual(r.year, 2024)
    }

    func testTitleThatIsAYear() {
        let r = p("Films/2012.mkv")
        XCTAssertEqual(r.title, "2012")
        XCTAssertNil(r.year)
    }

    func testTitleWithNumberKeepsLastYear() {
        let r = p("Films/2001 A Space Odyssey 1968.mkv")
        XCTAssertEqual(r.title, "2001 A Space Odyssey")
        XCTAssertEqual(r.year, 1968)
    }

    func testUnderscoresAndBrackets() {
        let r = p("Paper_Boats_[2015]_[YTS].mp4")
        XCTAssertEqual(r.title, "Paper Boats")
        XCTAssertEqual(r.year, 2015)
    }

    func testAudioChannelsNotSplitAsYear() {
        let r = p("Grain.2020.1080p.DD5.1.mp4")
        XCTAssertEqual(r.title, "Grain")
        XCTAssertEqual(r.year, 2020)
    }

    func testPlainTitleNoYear() {
        let r = p("random_clip_final.avi")
        XCTAssertEqual(r.title, "random clip final")
        XCTAssertNil(r.year)
        XCTAssertFalse(r.isEpisode)
    }

    func testHomeVideoDateIsNotAYearTitle() {
        let r = p("Home Videos/2023-08 Cornwall.mov")
        XCTAssertEqual(r.year, 2023)
        XCTAssertFalse(r.isEpisode)
    }
}
