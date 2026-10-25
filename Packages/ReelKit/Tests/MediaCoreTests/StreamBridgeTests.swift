import XCTest
import Foundation
import MediaCore
@testable import MediaSources

/// A source whose "file" is a byte pattern in memory, so the bridge can be exercised without a share.
actor PatternSource: MediaSource {
    nonisolated let config = SourceConfig(name: "pattern", type: .local)
    let bytes: Data
    init(size: Int) { bytes = Data((0..<size).map { UInt8($0 % 251) }) }
    func connect(credentials: Credentials?) async throws {}
    func list(_ relativePath: String) async throws -> [DirectoryEntry] { [] }
    func stat(_ relativePath: String) async throws -> DirectoryEntry { DirectoryEntry(name: "f", relativePath: relativePath, isDirectory: false, size: Int64(bytes.count), modified: nil) }
    func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL { URL(string: "pattern://f")! }
    func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {}
    func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        let start = Int(min(Int64(bytes.count), offset))
        return bytes.subdata(in: start..<min(bytes.count, start + length))
    }
    func disconnect() async {}
}

final class StreamBridgeTests: XCTestCase {
    func testRangeRequestsReturnTheRightBytes() async throws {
        let size = 3 * (1 << 20) + 123   // three chunks and a bit
        let source = PatternSource(size: size)
        StreamBridge.preferLoopback = true
        let bridge = StreamBridge()
        let url = try await bridge.register(source: source, path: "f.mp4", size: Int64(size))
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertTrue(url.lastPathComponent.hasSuffix("f.mp4"))

        // A middle range spanning a chunk boundary.
        var req = URLRequest(url: url)
        req.setValue("bytes=1048000-1049999", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 1048000-1049999/\(size)")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(data.count, 2000)
        let expected = await source.bytes.subdata(in: 1048000..<1050000)
        XCTAssertEqual(data, expected)

        // An open-ended range to the end of the file.
        var tail = URLRequest(url: url)
        tail.setValue("bytes=\(size - 100)-", forHTTPHeaderField: "Range")
        let (tailData, tailResponse) = try await URLSession.shared.data(for: tail)
        XCTAssertEqual((tailResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(tailData.count, 100)

        // No range: the whole file, in chunks.
        let (all, allResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((allResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(all.count, size)

        // A wrong token is not served.
        let bad = URL(string: "http://127.0.0.1:\(url.port!)/nope/f.mp4")!
        let (_, badResponse) = try await URLSession.shared.data(from: bad)
        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 404)
        await bridge.stop()
    }
}
