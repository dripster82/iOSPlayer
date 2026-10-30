import XCTest
@testable import Playback

final class FrameMatchTests: XCTestCase {
    private func print(seed: Int, shift: Int = 0) -> FrameFingerprint {
        // A deterministic texture: the shift moves it a little, as a second of motion would.
        let w = FrameFingerprint.width, h = FrameFingerprint.height
        var luma = [UInt8](repeating: 0, count: w * h)
        var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        var noise = [UInt8](repeating: 0, count: w * h + 8)
        for i in noise.indices { state = state &* 6364136223846793005 &+ 1442695040888963407; noise[i] = UInt8(truncatingIfNeeded: state >> 33) }
        for y in 0..<h { for x in 0..<w { luma[y * w + x] = noise[y * w + x + shift] } }
        return FrameFingerprint(luma: luma)
    }

    func testDistanceIsZeroForTheSameFrameAndLargeForAnother() {
        let a = print(seed: 1)
        XCTAssertEqual(a.distance(to: a), 0)
        XCTAssertGreaterThan(a.distance(to: print(seed: 7)), IntroLocator.threshold)
    }

    func testFlatFramesAreNotFingerprints() {
        XCTAssertTrue(FrameFingerprint(luma: [UInt8](repeating: 10, count: 32 * 18)).isFlat)
        XCTAssertFalse(print(seed: 1).isFlat)
        XCTAssertNil(IntroLocator.nearest(print(seed: 1), in: [FrameFingerprint(luma: [UInt8](repeating: 0, count: 32 * 18))]))
    }

    func testStartIsShiftedBackByTheMatchedFingerprintsOffset() {
        // Marked intro: fingerprints 2 s apart from 90 s. A coarse scan of the other episode every
        // 8 s hits the frame that is the third fingerprint (4 s into the intro) at 124 s.
        let targets = (0..<IntroLocator.count).map { print(seed: 10 + $0) }
        var samples = stride(from: 0.0, through: 200, by: IntroLocator.coarseStep).map { IntroLocator.Sample(time: $0, print: print(seed: 50 + Int($0))) }
        samples[15] = IntroLocator.Sample(time: 120, print: print(seed: 12))   // same picture as fingerprint 2
        XCTAssertEqual(IntroLocator.estimateStart(samples: samples, targets: targets), 116)
        XCTAssertNil(IntroLocator.estimateStart(samples: Array(samples[0..<10]), targets: targets), "nothing close enough: no start")
    }
}
