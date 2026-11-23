import XCTest
@testable import Playback

final class StreamHostTests: XCTestCase {
    func testDefaultPortByScheme() {
        let t = StreamHost.target(for: URL(string: "smb://user:secret@192.168.1.124/video/Film.mkv")!)
        XCTAssertEqual(t?.host, "192.168.1.124"); XCTAssertEqual(t?.port, 445)
        XCTAssertEqual(StreamHost.target(for: URL(string: "https://nas.example/dav/a.mkv")!)?.port, 443)
        XCTAssertEqual(StreamHost.target(for: URL(string: "ftp://nas/a.mkv")!)?.port, 21)
    }
    func testExplicitPortWins() {
        XCTAssertEqual(StreamHost.target(for: URL(string: "http://nas:8096/a.mkv")!)?.port, 8096)
    }
    func testNothingToAskLocally() {
        XCTAssertNil(StreamHost.target(for: URL(fileURLWithPath: "/tmp/a.mkv")))
        XCTAssertNil(StreamHost.target(for: URL(string: "http://127.0.0.1:8080/a.mkv")!))
        XCTAssertNil(StreamHost.target(for: URL(string: "http://localhost:8080/a.mkv")!))
        XCTAssertNil(StreamHost.target(for: URL(string: "rtsp://camera/stream")!))
    }
}
