import XCTest
@testable import Metadata

final class OpenSubtitlesClientTests: XCTestCase {
    private struct FakeTransport: HTTPTransport {
        var handler: @Sendable (URLRequest) throws -> (Data, URLResponse)
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { try handler(request) }
    }
    private func ok(_ json: String, for request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testSearchParsesResultsAndSendsEpisodeQuery() async throws {
        let seen = Captured()
        let transport = FakeTransport { req in
            seen.url = req.url; seen.apiKey = req.value(forHTTPHeaderField: "Api-Key")
            return self.ok(#"""
            {"data":[{"id":"1","attributes":{"language":"en","release":"Atlantis.S03E03.1080p","download_count":120,"hearing_impaired":false,"from_trusted":true,"files":[{"file_id":555,"file_name":"atlantis.srt"}]}},
                     {"id":"2","attributes":{"language":"en","files":[]}}]}
            """#, for: req)
        }
        let client = OpenSubtitlesClient(apiKey: "k", transport: transport)
        let results = try await client.search(parentTMDbID: 42, season: 3, episode: 3, languages: ["en"])
        XCTAssertEqual(results.count, 1, "a row with no file is skipped")
        XCTAssertEqual(results[0].fileID, 555)
        XCTAssertEqual(results[0].summary, "Atlantis.S03E03.1080p · trusted")
        XCTAssertEqual(seen.apiKey, "k")
        let query = seen.url?.query ?? ""
        XCTAssertTrue(query.contains("parent_tmdb_id=42") && query.contains("season_number=3") && query.contains("episode_number=3"), query)
    }

    func testDownloadNeedsLogin() async {
        let client = OpenSubtitlesClient(apiKey: "k", transport: FakeTransport { req in self.ok("{}", for: req) })
        XCTAssertFalse(client.canDownload)
        do { _ = try await client.download(fileID: 1); XCTFail("should throw") } catch let e as OpenSubtitlesError {
            if case .missingLogin = e {} else { XCTFail("wrong error \(e)") }
        } catch { XCTFail("wrong error \(error)") }
    }

    func testDownloadLogsInThenFollowsLink() async throws {
        let transport = FakeTransport { req in
            switch req.url!.path {
            case "/api/v1/login": return self.ok(#"{"token":"T"}"#, for: req)
            case "/api/v1/download":
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T")
                return self.ok(#"{"link":"https://dl.example/x.srt","file_name":"x.srt"}"#, for: req)
            default: return self.ok("1\n00:00:01,000 --> 00:00:02,000\nHi\n", for: req)
            }
        }
        let client = OpenSubtitlesClient(apiKey: "k", username: "u", password: "p", transport: transport)
        let (data, name) = try await client.download(fileID: 9)
        XCTAssertEqual(name, "x.srt")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Hi"))
    }

    func testQuotaErrorIsReadable() async {
        let transport = FakeTransport { req in
            if req.url!.path.hasSuffix("login") { return self.ok(#"{"token":"T"}"#, for: req) }
            return self.ok(#"{"message":"limit"}"#, for: req, status: 406)
        }
        let client = OpenSubtitlesClient(apiKey: "k", username: "u", password: "p", transport: transport)
        do { _ = try await client.download(fileID: 9); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "OpenSubtitles download limit reached for today.")
        }
    }
}

private final class Captured: @unchecked Sendable { var url: URL?; var apiKey: String? }
