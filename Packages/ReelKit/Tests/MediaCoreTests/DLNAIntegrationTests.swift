import XCTest
import MediaCore
@testable import MediaSources

/// Runs against a MiniDLNA on 127.0.0.1:8200 (the development setup, serving Films and TV folders);
/// skipped otherwise.
final class DLNAIntegrationTests: XCTestCase {
    private func serverIsUp() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8200/rootDesc.xml") else { return false }
        return (try? await URLSession.shared.data(from: url)) != nil
    }

    func testBrowseByHostOnly() async throws {
        let up = await serverIsUp()
        try XCTSkipUnless(up, "no MiniDLNA on 127.0.0.1:8200")
        let source = DLNASource(config: SourceConfig(name: "t", type: .dlna, host: "127.0.0.1"))
        let started = Date()
        try await source.connect(credentials: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "finding the description should not wait on every timeout")
        let root = try await source.list("")
        XCTAssertEqual(root.map(\.name).sorted(), ["Films", "TV"], "MiniDLNA's Video → Folders tree is the root")
    }

    func testWalkToAFilmAndReadIt() async throws {
        let up = await serverIsUp()
        try XCTSkipUnless(up, "no MiniDLNA on 127.0.0.1:8200")
        let source = DLNASource(config: SourceConfig(name: "t", type: .dlna, host: "127.0.0.1", path: "http://127.0.0.1:8200/rootDesc.xml"))
        try await source.connect(credentials: nil)
        // Depth-first until a video turns up (MiniDLNA groups by Video / Folders / All Video, and so on).
        var queue = try await source.list("").filter(\.isDirectory).map(\.relativePath)
        var film: DirectoryEntry?
        var visited = 0
        while film == nil, let dir = queue.first, visited < 40 {
            queue.removeFirst(); visited += 1
            let entries = try await source.list(dir)
            film = entries.first { !$0.isDirectory && $0.isVideo }
            queue += entries.filter(\.isDirectory).map(\.relativePath)
        }
        let found = try XCTUnwrap(film, "a video item somewhere under the root")
        XCTAssertTrue(found.name.hasSuffix(".mp4"), "the title gets the file's extension: \(found.name)")
        XCTAssertGreaterThan(found.size ?? 0, 0)

        let stat = try await source.stat(found.relativePath)
        XCTAssertEqual(stat.size, found.size)
        let url = try await source.playbackURL(found.relativePath, credentials: nil)
        XCTAssertEqual(url.scheme, "http")
        let head = try await source.read(found.relativePath, offset: 0, length: 4096)
        XCTAssertEqual(head.count, 4096)
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp")

        // A fresh source resolves the same path from scratch (after a relaunch, nothing is cached).
        let again = DLNASource(config: SourceConfig(name: "t", type: .dlna, host: "127.0.0.1", path: "http://127.0.0.1:8200/rootDesc.xml"))
        try await again.connect(credentials: nil)
        let resolved = try await again.playbackURL(found.relativePath, credentials: nil)
        XCTAssertEqual(resolved, url)
    }
}
