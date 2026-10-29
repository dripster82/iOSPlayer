import XCTest
import MediaCore
@testable import Metadata

/// Canned answers keyed by a substring of the full URL (query included), since Wikidata's two calls
/// share one path.
final class QueryTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(String, Data)] = []
    var calls: [URL] = []
    var headers: [[String: String]] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        calls.append(url); headers.append(request.allHTTPHeaderFields ?? [:])
        let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let hit = responses.first(where: { decoded.contains($0.0) }) else { throw URLError(.notConnectedToInternet) }
        return (hit.1, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class SecondOpinionTests: XCTestCase {
    private func tempCache() -> MetadataCache {
        MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), ttl: 60)
    }

    func testWikidataFilmsCarryTMDbIDYearAndIMDb() async throws {
        let t = QueryTransport()
        t.responses.append(("wbsearchentities", Data(#"{"search":[{"id":"Q24","label":"Up"},{"id":"Q25","label":"Up (band)"}]}"#.utf8)))
        t.responses.append(("wbgetentities", Data(#"""
        {"entities":{
          "Q24":{"labels":{"en":{"value":"Up"}},"claims":{
             "P4947":[{"rank":"normal","mainsnak":{"datavalue":{"value":"14160"}}}],
             "P345":[{"rank":"normal","mainsnak":{"datavalue":{"value":"tt1049413"}}}],
             "P577":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+2009-05-29T00:00:00Z"}}}}]}},
          "Q25":{"labels":{"en":{"value":"Up (band)"}},"claims":{}}
        }}
        """#.utf8)))
        let client = WikidataClient(transport: t, cache: tempCache())
        let hits = try await client.searchFilms(title: "Up")
        XCTAssertEqual(hits.count, 1, "an entity without a TMDb film id is not a film hit")
        XCTAssertEqual(hits[0], SecondOpinionHit(source: "Wikidata", title: "Up", year: 2009, tmdbID: 14160, imdbID: "tt1049413"))
        XCTAssertEqual(t.calls.count, 2)
        XCTAssertTrue(t.headers[0]["User-Agent"]?.hasPrefix("Reel/") ?? false, "Wikimedia asks for an identifying User-Agent")
        _ = try await client.searchFilms(title: "Up")
        XCTAssertEqual(t.calls.count, 2, "both calls are cached")
    }

    func testWikidataShowsUseSeriesIDAndStartTime() async throws {
        let t = QueryTransport()
        t.responses.append(("wbsearchentities", Data(#"{"search":[{"id":"Q1"}]}"#.utf8)))
        t.responses.append(("wbgetentities", Data(#"""
        {"entities":{"Q1":{"labels":{"en":{"value":"Bluey"}},"claims":{
          "P4983":[{"rank":"normal","mainsnak":{"datavalue":{"value":"82728"}}}],
          "P580":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+2018-10-01T00:00:00Z"}}}}]}}}}
        """#.utf8)))
        let hits = try await WikidataClient(transport: t, cache: tempCache()).searchShows(title: "Bluey")
        XCTAssertEqual(hits.first?.tmdbID, 82728)
        XCTAssertEqual(hits.first?.year, 2018)
        let asFilm = try await WikidataClient(transport: t, cache: tempCache()).searchFilms(title: "Bluey")
        XCTAssertTrue(asFilm.isEmpty, "a series is not a film")
    }

    func testTVmazeGivesExternalIDsAndPremiereYear() async throws {
        let t = QueryTransport()
        t.responses.append(("search/shows", Data(#"""
        [{"score":0.9,"show":{"id":1,"name":"Bluey","premiered":"2018-10-01","externals":{"tvrage":null,"thetvdb":352636,"imdb":"tt7678620"}}},
         {"score":0.5,"show":{"id":2,"name":"Bluey (1990)","premiered":null,"externals":{}}}]
        """#.utf8)))
        let hits = try await TVmazeClient(transport: t, cache: tempCache()).searchShows(title: "Bluey")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0], SecondOpinionHit(source: "TVmaze", title: "Bluey", year: 2018, imdbID: "tt7678620", tvdbID: 352636))
        XCTAssertNil(hits[1].year); XCTAssertNil(hits[1].imdbID)
    }

    func testKitsuMapsAnimeToAniDB() async throws {
        let t = QueryTransport()
        t.responses.append(("/anime", Data(#"""
        {"data":[{"id":"7","type":"anime","attributes":{"canonicalTitle":"Sword Art Online","startDate":"2012-07-08","episodeCount":25},
                  "relationships":{"mappings":{"data":[{"type":"mappings","id":"m1"},{"type":"mappings","id":"m2"}]}}},
                 {"id":"8","type":"anime","attributes":{"canonicalTitle":"Sword Art Online II","startDate":"2014-07-05"},
                  "relationships":{"mappings":{"data":[]}}}],
         "included":[{"id":"m1","type":"mappings","attributes":{"externalSite":"myanimelist/anime","externalId":"11757"}},
                     {"id":"m2","type":"mappings","attributes":{"externalSite":"anidb","externalId":"8692"}}]}
        """#.utf8)))
        let hits = try await KitsuClient(transport: t, cache: tempCache()).searchAnime(title: "Sword Art Online")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0], SecondOpinionHit(source: "Kitsu", title: "Sword Art Online", year: 2012, anidbID: 8692))
        XCTAssertNil(hits[1].anidbID)
        XCTAssertEqual(t.headers[0]["Accept"], "application/vnd.api+json")
    }

    func testTitlesCompareLikeTheScorer() {
        XCTAssertEqual(opinionNormalise("The LEGO Movie"), opinionNormalise("The Lego Movie"))
    }
}
