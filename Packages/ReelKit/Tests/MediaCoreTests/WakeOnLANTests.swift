import XCTest
@testable import MediaSources

final class WakeOnLANTests: XCTestCase {
    func testParsesCommonForms() {
        XCTAssertEqual(WakeOnLAN.normalise("a1:b2:c3:d4:e5:f6"), "A1:B2:C3:D4:E5:F6")
        XCTAssertEqual(WakeOnLAN.normalise("A1-B2-C3-D4-E5-F6"), "A1:B2:C3:D4:E5:F6")
        XCTAssertEqual(WakeOnLAN.normalise("a1b2c3d4e5f6"), "A1:B2:C3:D4:E5:F6")
        XCTAssertEqual(WakeOnLAN.parse("00:11:22:33:44:55"), [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
    }
    func testRejectsBadForms() {
        XCTAssertNil(WakeOnLAN.normalise(""))
        XCTAssertNil(WakeOnLAN.normalise("a1:b2:c3:d4:e5"))
        XCTAssertNil(WakeOnLAN.normalise("zz:b2:c3:d4:e5:f6"))
        XCTAssertNil(WakeOnLAN.normalise("192.168.1.20"))
    }
}
