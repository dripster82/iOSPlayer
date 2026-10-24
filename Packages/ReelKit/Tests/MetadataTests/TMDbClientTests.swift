import XCTest
import MediaCore
@testable import Metadata

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: (Int, Data)] = [:]
    var calls: [URL] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        calls.append(url)
        let path = url.path
        guard let hit = responses.first(where: { path.hasSuffix($0.key) }) else {
            throw URLError(.notConnectedToInternet)
        }
        let (status, data) = hit.value
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class TMDbClientTests: XCTestCase {

    private func tempCache() -> MetadataCache {
        MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), ttl: 60)
    }

    func testSearchMoviesDecodesAndCaches() async throws {
        let transport = MockTransport()
        transport.responses["/search/movie"] = (200, Data(#"{"page":1,"total_results":1,"results":[{"id":42,"title":"Null Island","release_date":"2024-03-01","popularity":12.5}]}"#.utf8))
        let client = TMDbClient(apiKey: "k", transport: transport, cache: tempCache())
        let first = try await client.searchMovies(query: "Null Island", year: 2024)
        XCTAssertEqual(first.first?.id, 42)
        XCTAssertEqual(first.first?.year, 2024)
        _ = try await client.searchMovies(query: "Null Island", year: 2024)
        XCTAssertEqual(transport.calls.count, 1, "second call should be served from cache")
        XCTAssertFalse(transport.calls[0].absoluteString.isEmpty)
        XCTAssertTrue(transport.calls[0].query?.contains("api_key=k") ?? false)
    }

    func testMissingKeyThrows() async {
        let client = TMDbClient(apiKey: "", transport: MockTransport(), cache: tempCache())
        do { _ = try await client.searchShows(query: "x"); XCTFail() }
        catch let e as TMDbError { if case .missingAPIKey = e {} else { XCTFail() } }
        catch { XCTFail() }
    }

    func testHTTPErrorSurfaces() async {
        let transport = MockTransport()
        transport.responses["/movie/1"] = (404, Data("{}".utf8))
        let client = TMDbClient(apiKey: "k", transport: transport, cache: tempCache())
        do { _ = try await client.movie(id: 1); XCTFail() }
        catch let e as TMDbError { if case .http(404) = e {} else { XCTFail("\(e)") } }
        catch { XCTFail() }
    }

    func testOfflineWithoutCache() async {
        let client = TMDbClient(apiKey: "k", transport: MockTransport(), cache: tempCache())
        do { _ = try await client.show(id: 9); XCTFail() }
        catch let e as TMDbError { if case .offlineNoCache = e {} else { XCTFail() } }
        catch { XCTFail() }
    }
}

final class MatchScorerTests: XCTestCase {
    private func movie(_ id: Int, _ title: String, _ year: Int?, pop: Double = 10) -> TMDbMovieSummary {
        let json = """
        {"id":\(id),"title":"\(title)","release_date":\(year.map { "\"\($0)-01-01\"" } ?? "null"),"popularity":\(pop)}
        """
        return try! JSONDecoder().decode(TMDbMovieSummary.self, from: Data(json.utf8))
    }

    func testExactTitleAndYearIsHigh() {
        let d = MatchScorer.decideMovie([movie(1, "Null Island", 2024), movie(2, "Island Zero", 2024)], parsed: ParsedName(title: "Null Island", year: 2024))
        XCTAssertEqual(d.pick?.id, 1)
        XCTAssertEqual(d.confidence, .autoHigh)
    }

    func testTwoCloseCandidatesAreLow() {
        let d = MatchScorer.decideMovie([movie(1, "Grain", 2020), movie(2, "Grain", 2021)], parsed: ParsedName(title: "Grain", year: nil))
        XCTAssertNotNil(d.pick)
        XCTAssertEqual(d.confidence, .autoLow)
    }

    func testNoResultsUnmatched() {
        XCTAssertEqual(MatchScorer.decideMovie([], parsed: ParsedName(title: "x")).confidence, .unmatched)
    }

    func testArticlesIgnored() {
        XCTAssertEqual(MatchScorer.normalise("The Last Projectionist"), MatchScorer.normalise("Last Projectionist"))
    }

    // Weaker evidence is accepted as autoLow (flagged "?") rather than sent to Needs Review.

    func testSingleResultFromAlternativeTitleIsLow() {
        // "Shingeki no Kyojin" → TMDb's only hit is "Attack on Titan": no title overlap at all.
        let d = MatchScorer.decideMovie([movie(1, "Attack on Titan", 2013, pop: 56)], parsed: ParsedName(title: "Shingeki no Kyojin"))
        XCTAssertEqual(d.pick?.id, 1)
        XCTAssertEqual(d.confidence, .autoLow)
    }

    func testSimilarTitleAmongSeveralIsLow() {
        let d = MatchScorer.decideMovie([movie(1, "Ninjago: Masters of Spinjitzu", 2011, pop: 20), movie(2, "Ninjago Dragons Rising", 2023, pop: 30)], parsed: ParsedName(title: "LEGO Ninjago Masters of Spinjitzu"))
        XCTAssertEqual(d.pick?.id, 1)
        XCTAssertEqual(d.confidence, .autoLow)
    }

    func testSingleResultWithClashingYearStaysUnmatched() {
        let d = MatchScorer.decideMovie([movie(1, "Blackadder", 1983, pop: 29)], parsed: ParsedName(title: "Some Other Thing", year: 2021))
        XCTAssertNil(d.pick)
        XCTAssertEqual(d.confidence, .unmatched)
    }
}
