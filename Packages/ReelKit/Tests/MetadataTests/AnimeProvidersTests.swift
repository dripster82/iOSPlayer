import XCTest
import MediaCore
@testable import Metadata

final class AnimeListsTests: XCTestCase {
    // Trimmed from the real anime-list-full.xml: Sword Art Online and its continuations.
    private let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <anime-list>
      <anime anidbid="8692" tvdbid="259640" defaulttvdbseason="1" tmdbtv="45782" tmdbseason="1">
        <name>Sword Art Online</name>
        <mapping-list>
          <mapping anidbseason="0" tvdbseason="0" start="1" end="9" offset="0"/>
        </mapping-list>
      </anime>
      <anime anidbid="14796" tvdbid="259640" defaulttvdbseason="4" tmdbtv="45782" tmdbseason="4">
        <name>Sword Art Online: Alicization - War of Underworld</name>
        <mapping-list>
          <mapping anidbseason="0" tvdbseason="0">;1-26;</mapping>
        </mapping-list>
      </anime>
      <anime anidbid="15146" tvdbid="259640" defaulttvdbseason="4" episodeoffset="12" tmdbtv="45782" tmdbseason="4" tmdboffset="12">
        <name>Sword Art Online: Alicization - War of Underworld (2020)</name>
      </anime>
      <anime anidbid="19" tvdbid="83692" defaulttvdbseason="a" tmdbtv="34684" tmdbseason="a">
        <name>Rizelmine</name>
      </anime>
      <anime anidbid="10022" tvdbid="movie" tmdbid="12345">
        <name>Some Film</name>
      </anime>
    </anime-list>
    """

    private var entries: [Int: AnimeLists.Entry] { AnimeLists.parse(xml: Data(fixture.utf8)) }

    func testParsesAttributesAndMappings() {
        let e = entries
        XCTAssertEqual(e.count, 5)
        XCTAssertEqual(e[8692]?.tmdbTV, 45782)
        XCTAssertEqual(e[8692]?.mappings.first?.start, 1)
        XCTAssertEqual(e[14796]?.mappings.first?.pairs[1], 26)
        XCTAssertEqual(e[15146]?.tmdbOffset, 12)
        XCTAssertEqual(e[10022]?.tmdbMovie, 12345)
        XCTAssertEqual(e[10022]?.name, "Some Film")
    }

    func testRegularEpisodeUsesDefaultSeasonAndOffset() {
        XCTAssertEqual(entries[15146]?.resolve(anidbSeason: 1, episode: 3), .init(tmdbShow: 45782, season: 4, episode: 15))
        XCTAssertEqual(entries[14796]?.resolve(anidbSeason: 1, episode: 3), .init(tmdbShow: 45782, season: 4, episode: 3))
        XCTAssertEqual(entries[8692]?.resolve(anidbSeason: 1, episode: 7), .init(tmdbShow: 45782, season: 1, episode: 7))
    }

    func testSpecialsUseExplicitPairsOrRange() {
        XCTAssertEqual(entries[14796]?.resolve(anidbSeason: 0, episode: 1), .init(tmdbShow: 45782, season: 0, episode: 26))
        XCTAssertEqual(entries[8692]?.resolve(anidbSeason: 0, episode: 4), .init(tmdbShow: 45782, season: 0, episode: 4))
    }

    func testAbsoluteNumberingFallsBackToSeasonOne() {
        XCTAssertEqual(entries[19]?.resolve(anidbSeason: 1, episode: 5), .init(tmdbShow: 34684, season: 1, episode: 5))
    }

    func testEntryWithoutShowDoesNotResolve() {
        XCTAssertNil(entries[10022]?.resolve(anidbSeason: 1, episode: 1))
    }
}

final class AniDBTitlesTests: XCTestCase {
    private let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <animetitles>
      <anime aid="15146">
        <title type="short" xml:lang="ja">sao4 part 2</title>
        <title xml:lang="en" type="official">Sword Art Online: Alicization - War of Underworld (2020)</title>
        <title xml:lang="x-jat" type="main">Sword Art Online: Alicization - War of Underworld (2020)</title>
        <title type="syn" xml:lang="en">Sword Art Online: Alicization - War of Underworld Part 2</title>
      </anime>
      <anime aid="15775">
        <title xml:lang="x-jat" type="main">Hataraku Saibou Black</title>
        <title xml:lang="en" type="official">Cells at Work! CODE BLACK</title>
        <title xml:lang="ja" type="kana">はたらくさいぼうブラック</title>
      </anime>
    </animetitles>
    """

    func testIndexesMainOfficialAndSynonymsButNotShortOrKana() {
        let index = AniDBTitles.parse(xml: Data(fixture.utf8))
        XCTAssertEqual(index.titles[MatchScorer.normalise("Hataraku Saibou Black")], [15775])
        XCTAssertEqual(index.titles[MatchScorer.normalise("Cells at Work! CODE BLACK")], [15775])
        XCTAssertEqual(index.titles[MatchScorer.normalise("Sword Art Online Alicization War of Underworld Part 2")], [15146])
        XCTAssertNil(index.titles[MatchScorer.normalise("sao4 part 2")])
        XCTAssertEqual(index.mainTitles[15775], "Hataraku Saibou Black")
    }

    func testLookupUsesCachedIndexWithoutNetwork() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = AniDBTitles.parse(xml: Data(fixture.utf8))
        try? JSONEncoder().encode(index).write(to: dir.appendingPathComponent("anidb-titles.json"))
        let titles = AniDBTitles(directory: dir, transport: MockTransport())
        let hits = await titles.lookup("cells at work code black")
        XCTAssertEqual(hits.map(\.aid), [15775])
        XCTAssertEqual(hits.first?.title, "Hataraku Saibou Black")
        let miss = await titles.lookup("No Such Show")
        XCTAssertTrue(miss.isEmpty)
    }

    func testGunzipStripsHeaderAndInflates() throws {
        // `printf 'hello anidb' | gzip -n | base64`
        let gz = Data(base64Encoded: "H4sIAAAAAAAAA8tIzcnJV0jMy0xJAgBud59rCwAAAA==")!
        let out = try Gunzip.decompress(gz)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello anidb")
    }

    /// Runs only when the real dump files are present (fetched during development); guards the parsers
    /// against format drift in the live data.
    func testRealDumpsIfPresent() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/claude-502/-Users-paulketelle--claude-spares-spare-lL8REA/0e38825e-f347-4e63-b12a-53b3a55fef03/scratchpad/anime")
        guard let titlesXML = try? Data(contentsOf: dir.appendingPathComponent("anime-titles.xml")),
              let listXML = try? Data(contentsOf: dir.appendingPathComponent("anime-list-full.xml")) else { throw XCTSkip("real dumps not present") }
        let titles = AniDBTitles.parse(xml: titlesXML)
        let lists = AnimeLists.parse(xml: listXML)
        XCTAssertGreaterThan(titles.mainTitles.count, 15_000)
        XCTAssertGreaterThan(lists.count, 10_000)
        let aids = titles.titles[MatchScorer.normalise("Shingeki no Kyojin")] ?? []
        XCTAssertFalse(aids.isEmpty, "Attack on Titan should be found by its romaji title")
        let wou2020 = titles.titles[MatchScorer.normalise("Sword Art Online: Alicization - War of Underworld (2020)")] ?? []
        XCTAssertEqual(wou2020, [15146])
        XCTAssertEqual(lists[15146]?.resolve(anidbSeason: 1, episode: 3), .init(tmdbShow: 45782, season: 4, episode: 15))
    }
}

final class TVDBClientTests: XCTestCase {
    func testLoginThenSearchBridgesToTMDbID() async throws {
        let transport = MockTransport()
        transport.responses["/login"] = (200, Data(#"{"status":"success","data":{"token":"tok"}}"#.utf8))
        transport.responses["/search"] = (200, Data(#"{"status":"success","data":[{"objectID":"series-259640","tvdb_id":"259640","name":"Sword Art Online","year":"2012","overview":"...","image_url":"https://artworks.thetvdb.com/x.jpg","remote_ids":[{"id":"tt2250192","type":2,"sourceName":"IMDB"},{"id":"45782","type":12,"sourceName":"TheMovieDB.com"}]}]}"#.utf8))
        let cache = MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), ttl: 60)
        let client = TVDBClient(apiKey: "k", transport: transport, cache: cache)
        let results = try await client.searchSeries(query: "Sword Art Online")
        XCTAssertEqual(results.first?.id, 259640)
        XCTAssertEqual(results.first?.tmdbID, 45782)
        XCTAssertEqual(results.first?.year, 2012)
        XCTAssertEqual(transport.calls.map(\.path), ["/v4/login", "/v4/search"])
    }

    func testMissingKeyThrows() async {
        let client = TVDBClient(apiKey: "", transport: MockTransport())
        do { _ = try await client.searchSeries(query: "x"); XCTFail() }
        catch let e as TVDBError { if case .missingAPIKey = e {} else { XCTFail() } }
        catch { XCTFail() }
    }
}
