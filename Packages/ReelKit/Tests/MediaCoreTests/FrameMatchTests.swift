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
        XCTAssertEqual(a.similarity(to: a), 1, accuracy: 0.0001)
        XCTAssertLessThan(abs(a.similarity(to: print(seed: 7))), 0.3)
        // The same picture, darker and flatter (another encode's levels), is still the same picture.
        let dim = FrameFingerprint(luma: a.luma.map { UInt8(Double($0) * 0.6 + 20) })
        XCTAssertGreaterThan(a.similarity(to: dim), 0.99)
        XCTAssertNotNil(IntroLocator.matches(dim, in: [print(seed: 2), a]))
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
        var samples = stride(from: 0.0, through: 200, by: 8).map { IntroLocator.Sample(time: $0, print: print(seed: 50 + Int($0))) }
        samples[15] = IntroLocator.Sample(time: 120, print: print(seed: 12))   // same picture as fingerprint 2
        XCTAssertEqual(IntroLocator.estimateStart(samples: samples, targets: targets, spacing: 2), 116)
        XCTAssertEqual(IntroLocator.coarseStep(forPrints: 55, spacing: 1), 52, "a 54 s set of prints: one sample every 52 s lands in it")
        XCTAssertEqual(IntroLocator.coarseStep(forPrints: 221, spacing: 0.25), 53)
        let encoded = try! JSONEncoder().encode(print(seed: 3))
        XCTAssertLessThan(encoded.count, 900, "a print is stored as bytes, not an array of numbers")
        XCTAssertEqual(try! JSONDecoder().decode(FrameFingerprint.self, from: encoded), print(seed: 3))
        let old = Data("{\"luma\":[\(Array(repeating: "7", count: 32 * 18).joined(separator: ","))]}".utf8)
        XCTAssertEqual(try! JSONDecoder().decode(FrameFingerprint.self, from: old).luma.count, 32 * 18, "the earlier array form still reads")
        XCTAssertEqual(IntroLocator.coarseStep(forPrints: 20, spacing: 2), 36)
        XCTAssertNil(IntroLocator.estimateStart(samples: Array(samples[0..<10]), targets: targets), "nothing close enough: no start")
    }

    func testDarkCardsNeedACloserMatch() {
        // Two credits cards: mostly black, a few light pixels in different places. Their mean
        // difference is small in absolute terms but large against their own brightness.
        let n = FrameFingerprint.width * FrameFingerprint.height
        var a = [UInt8](repeating: 4, count: n), b = a
        for i in stride(from: 40, to: 120, by: 3) { a[i] = 200 }
        for i in stride(from: 300, to: 380, by: 3) { b[i] = 200 }
        let pa = FrameFingerprint(luma: a), pb = FrameFingerprint(luma: b)
        XCTAssertLessThan(pa.distance(to: pb), IntroLocator.threshold, "mostly black: a small absolute difference")
        XCTAssertLessThan(pa.similarity(to: pb), 0.2)
        XCTAssertNil(IntroLocator.matches(pa, in: [pb]), "but not the same card")
        XCTAssertNotNil(IntroLocator.matches(pa, in: [pa]))
    }
}
