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
