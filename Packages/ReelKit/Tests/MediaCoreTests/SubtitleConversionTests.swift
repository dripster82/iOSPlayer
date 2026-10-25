import XCTest
@testable import Playback

final class SubtitleConversionTests: XCTestCase {
    func testSRTBecomesWebVTTWithShiftedCues() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello

        2
        00:01:02,250 --> 00:01:04,000
        Two lines
        here

        """
        let vtt = SubtitleConversion.webVTT(from: Data(srt.utf8), shiftingBy: 2)!
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:01.500\nHello"), "a cue that straddles the start is clipped to zero")
        XCTAssertTrue(vtt.contains("00:01:00.250 --> 00:01:02.000\nTwo lines\nhere"))
        XCTAssertFalse(vtt.contains("\n1\n"), "SRT cue numbers are dropped")
    }

    func testCuesBeforeTheOffsetAreDropped() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nGone\n\n2\n00:00:10,000 --> 00:00:11,000\nKept\n"
        let vtt = SubtitleConversion.webVTT(from: Data(srt.utf8), shiftingBy: 5)!
        XCTAssertFalse(vtt.contains("Gone"))
        XCTAssertTrue(vtt.contains("00:00:05.000 --> 00:00:06.000\nKept"))
    }
}

final class CodecNameTests: XCTestCase {
    private func mp4a(oti: UInt8) -> Data {
        // 28-byte sound description body, then an esds whose DecoderConfigDescriptor names the codec.
        var entry = Data(count: 28)
        let es: [UInt8] = [0, 0, 0, 0, 0x03, 0x19, 0x00, 0x02, 0x00, 0x04, 0x11, oti, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 0x02, 0x11, 0x90, 0x06, 0x01, 0x02]
        var esds = Data(); esds.append(contentsOf: withUnsafeBytes(of: UInt32(8 + es.count).bigEndian) { Data($0) }); esds.append(contentsOf: Array("esds".utf8)); esds.append(contentsOf: es)
        entry.append(esds)
        return entry
    }
    func testAACAndMP3AreToldApart() {
        XCTAssertEqual(MP4Boxes.codecName(of: .leaf(type: "mp4a", payload: mp4a(oti: 0x40))), "mp4a")
        XCTAssertEqual(MP4Boxes.codecName(of: .leaf(type: "mp4a", payload: mp4a(oti: 0x6B))), "mp3")
        XCTAssertEqual(MP4Boxes.codecName(of: .leaf(type: "ac-3", payload: Data(count: 40))), "ac-3")
        XCTAssertFalse(MP4Boxes.airPlayVideo.contains("mp4v"))
        XCTAssertEqual(MP4Boxes.describe(codec: "mp4v"), "MPEG-4 Part 2 (XviD/DivX)")
    }
}
