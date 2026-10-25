import XCTest
import MediaCore
@testable import MediaSources

final class SourceDiscoveryTests: XCTestCase {
    func testSubnetAddresses() {
        let all = SourceDiscovery.addresses(in: "192.168.1.136", prefix: 24)
        XCTAssertEqual(all.count, 253, "254 hosts less the device itself")
        XCTAssertEqual(all.first, "192.168.1.1")
        XCTAssertEqual(all.last, "192.168.1.254")
        XCTAssertFalse(all.contains("192.168.1.136"))
        XCTAssertEqual(SourceDiscovery.addresses(in: "10.0.0.5", prefix: 30), ["10.0.0.6"])
        XCTAssertEqual(SourceDiscovery.describe("192.168.1.136", prefix: 24), "192.168.1.0/24")
        XCTAssertTrue(SourceDiscovery.addresses(in: "not an address", prefix: 24).isEmpty)
    }

    /// Sweeps the Mac's own Wi-Fi subnet; only checks that it finishes and reports a network.
    @MainActor
    func testSweepFinishes() async throws {
        try XCTSkipUnless(SourceDiscovery.wifiNetwork() != nil, "no Wi-Fi interface")
        let d = SourceDiscovery()
        d.sweepSubnet()
        XCTAssertNotNil(d.sweepStatus)
        let deadline = Date().addingTimeInterval(60)
        while d.sweepStatus != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertNil(d.sweepStatus, "the sweep ends within a minute")
        print("sweep found:", d.hosts.map { "\($0.type.rawValue) \($0.name) (\($0.host))\($0.path.isEmpty ? "" : " " + $0.path)" })
    }
}
