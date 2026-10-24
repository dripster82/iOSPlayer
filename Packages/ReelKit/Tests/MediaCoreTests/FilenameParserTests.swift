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

    // MARK: - Anime / fansub shapes (from a real 4,000-file library)

    func testFansubGroupUnderscoreDashEpisode() {
        let r = p("Torrents/2 Sort/Hataraku Saibou Black/[DB]Hataraku Saibou Black_-_01_(Dual Audio_10bit_1080p_x265).mkv")
        XCTAssertEqual(r.title, "Hataraku Saibou Black")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 1)
        XCTAssertTrue(r.quality.contains("1080p"))
    }

    func testParenGroupPrefix() {
        let r = p("Torrents/2 Sort/Tokyo Underground/(Hi10)_Tokyo_Underground_-_01_(480p)_(V-A).mkv")
        XCTAssertEqual(r.title, "Tokyo Underground")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 1)
    }

    func testEpisodeVersionSuffix() {
        let r = p("Is It Wrong to Try to Pick Up Girls in a Dungeon - S03E11v2 (BDRip 1920x1080 x265 10-bit AAC) [Dual Audio].mkv")
        XCTAssertEqual(r.title, "Is It Wrong to Try to Pick Up Girls in a Dungeon")
        XCTAssertEqual(r.season, 3)
        XCTAssertEqual(r.episode, 11)
    }

    func testEpPrefixNoSeason() {
        let r = p("Torrents/2 Sort/[E-D] .Hack Sign/[Exiled-Destiny]_Hack_Sign_Ep01_(55A4696B).mkv")
        XCTAssertEqual(r.title, "Hack Sign")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 1)
    }

    func testOrdinalSeasonInTitle() {
        let r = p("[Cleo]Sword_Art_Online_Alicization_War_of_Underworld_2nd_Season_-_01_(Dual Audio_10bit_1080p_x265).mkv")
        XCTAssertEqual(r.title, "Sword Art Online Alicization War of Underworld")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 1)
    }

    func testEpisodeWordWithSeasonInShowFolder() {
        let r = p("Torrents/2 Sort/My Hero Academia Complete Season 2/Episode 0 Hero Notebook.mkv")
        XCTAssertEqual(r.title, "My Hero Academia")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 0)
    }

    func testOVAFolderIsSeasonZero() {
        let r = p("[kmplx] My Teen Romantic Comedy SNAFU (BD 1080p x265)/S1 - My Teen Romantic Comedy SNAFU/OVA/OVA 01 - We Must Wish Them The Very Best.mkv")
        XCTAssertEqual(r.title, "My Teen Romantic Comedy SNAFU")
        XCTAssertEqual(r.season, 0)
        XCTAssertEqual(r.episode, 1)
    }

    func testDashYearIsNotAnEpisode() {
        let r = p("Films/Blade Runner 2049 - 2017.mkv")
        XCTAssertNil(r.episode)
        XCTAssertEqual(r.year, 2017)
    }
}
