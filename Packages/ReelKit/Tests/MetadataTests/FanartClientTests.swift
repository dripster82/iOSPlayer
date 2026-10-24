import XCTest
@testable import Metadata

final class FanartClientTests: XCTestCase {
    private struct FakeTransport: HTTPTransport {
        var handler: @Sendable (URLRequest) throws -> (Data, URLResponse)
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { try handler(request) }
    }
    private func ok(_ json: String, for request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testPrefersHDLogoInOwnLanguageThenNeutral() async throws {
        let transport = FakeTransport { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/tv/1234"))
            XCTAssertTrue(req.url!.query!.contains("api_key=k"))
            return self.ok(#"""
            {"name":"Atlantis","hdtvlogo":[{"id":"1","url":"https://a/de.png","lang":"de","likes":"9"},{"id":"2","url":"https://a/en.png","lang":"en","likes":"3"}],
             "clearlogo":[{"id":"3","url":"https://a/old.png","lang":"en","likes":"50"}],
             "showbackground":[{"id":"4","url":"https://a/bg1.jpg","lang":"","likes":"1"},{"id":"5","url":"https://a/bg2.jpg","lang":"","likes":"7"}]}
            """#, for: req)
        }
        let art = try await FanartClient(apiKey: "k", language: "en-GB", transport: transport, cache: MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))).show(tvdbID: 1234)
        XCTAssertEqual(art.logoURL, "https://a/en.png", "HD set wins over the more-liked SD logo")
        XCTAssertEqual(art.backgroundURLs, ["https://a/bg2.jpg", "https://a/bg1.jpg"], "most liked first")
        XCTAssertNil(art.clearArtURL)
    }

    func testNotFoundIsReadable() async {
        let client = FanartClient(apiKey: "k", transport: FakeTransport { req in self.ok("{}", for: req, status: 404) }, cache: MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        do { _ = try await client.movie(tmdbID: 1); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "fanart.tv has no artwork for this title.") }
    }
}
