import XCTest
import Network
import MediaCore
@testable import MediaSources

/// Runs against a local FTP server when one is listening on 127.0.0.1:2121 (the pyftpdlib server
/// used during development, serving a Films folder with anonymous access); skipped otherwise.
final class FTPIntegrationTests: XCTestCase {
    private func serverIsUp() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: UInt16(2121).bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    func testListStatReadAndDownload() async throws {
        try XCTSkipUnless(serverIsUp(), "no FTP server on 127.0.0.1:2121")
        let source = FTPSource(config: SourceConfig(name: "t", type: .ftp, host: "127.0.0.1", port: 2121, path: "/"))
        try await source.connect(credentials: nil)
        let root = try await source.list("")
        XCTAssertTrue(root.contains { $0.name == "Films" && $0.isDirectory })
        let films = try await source.list("Films")
        let film = try XCTUnwrap(films.first { $0.isVideo })
        XCTAssertGreaterThan(film.size ?? 0, 0)
        XCTAssertNotNil(film.modified)

        let stat = try await source.stat(film.relativePath)
        XCTAssertEqual(stat.size, film.size)

        // Ranged reads: the head of the file, then a window from the middle, both the asked-for length.
        let head = try await source.read(film.relativePath, offset: 0, length: 64 * 1024)
        XCTAssertEqual(head.count, 64 * 1024)
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp", "an MP4 starts with its ftyp box")
        let middle = try await source.read(film.relativePath, offset: 300_000, length: 100_000)
        XCTAssertEqual(middle.count, 100_000)
        // The same window again: the control connection survived the dropped data connection.
        let again = try await source.read(film.relativePath, offset: 300_000, length: 100_000)
        XCTAssertEqual(again, middle)

        let url = try await source.playbackURL(film.relativePath, credentials: nil)
        XCTAssertEqual(url.scheme, "ftp")
        XCTAssertTrue(url.path.hasSuffix(film.name))

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        var lastTotal: Int64 = 0
        try await source.download(film.relativePath, to: dest) { _, total in lastTotal = total; return true }
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64
        XCTAssertEqual(size, film.size)
        XCTAssertEqual(lastTotal, film.size)
        await source.disconnect()
    }

    func testWrongPasswordIsAuthFailure() async throws {
        try XCTSkipUnless(serverIsUp(), "no FTP server on 127.0.0.1:2121")
        let source = FTPSource(config: SourceConfig(name: "t", type: .ftp, host: "127.0.0.1", port: 2121, path: "/"))
        do {
            try await source.connect(credentials: Credentials(username: "reel", password: "wrong"))
            XCTFail("expected a rejection")
        } catch SourceError.authFailed {
        }
    }
}
