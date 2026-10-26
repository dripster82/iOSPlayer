import XCTest
import CoreGraphics
@testable import MediaCore
@testable import Playback

final class CreditsDetectionTests: XCTestCase {
    // MARK: Chapters

    func testNamedCreditsChapterWins() {
        let chapters = [Chapter(id: 0, title: "Story", start: 0, duration: 2400), Chapter(id: 1, title: "End Credits", start: 2400, duration: 60)]
        XCTAssertEqual(chapters.creditsStart(fileDuration: 2460), 2400)
    }

    func testOpeningCreditsEarlyAreNotTheEnd() {
        let chapters = [Chapter(id: 0, title: "Opening Credits", start: 0, duration: 60), Chapter(id: 1, title: "Story", start: 60, duration: 2400)]
        XCTAssertNil(chapters.creditsStart(fileDuration: 2460))
    }

    func testShortUnnamedFinalChapterIsTheCredits() {
        let chapters = [Chapter(id: 0, title: "Chapter 1", start: 0, duration: 1200), Chapter(id: 1, title: "Chapter 2", start: 1200, duration: 1300), Chapter(id: 2, title: "Chapter 3", start: 2500, duration: 50)]
        XCTAssertEqual(chapters.creditsStart(fileDuration: 2550), 2500)
    }

    func testLongUnnamedFinalChapterIsAScene() {
        let chapters = [Chapter(id: 0, title: "Chapter 1", start: 0, duration: 1200), Chapter(id: 1, title: "Chapter 2", start: 1200, duration: 900), Chapter(id: 2, title: "Chapter 3", start: 2100, duration: 450)]
        XCTAssertNil(chapters.creditsStart(fileDuration: 2550))
    }

    func testFilmWithFewLongChaptersMatchesNothing() {
        let chapters = [Chapter(id: 0, title: "Chapter 1", start: 0, duration: 3000), Chapter(id: 1, title: "Chapter 2", start: 3000, duration: 3000)]
        XCTAssertNil(chapters.creditsStart(fileDuration: 6000))
    }

    // MARK: Frames

    private func grid(_ draw: (inout [UInt8], Int, Int) -> Void) -> CreditsFrame.Grid {
        let w = CreditsFrame.gridWidth, h = CreditsFrame.gridHeight
        var luma = [UInt8](repeating: 0, count: w * h)
        draw(&luma, w, h)
        return CreditsFrame.Grid(width: w, height: h, luma: luma)
    }

    /// Lines of "text": short bright dashes with gaps, on rows a few apart.
    private func textRows(_ luma: inout [UInt8], _ w: Int, _ h: Int, rows: [Int], from: Int = 20, to: Int = 76) {
        for y in rows { var x = from; while x < to { for dx in 0..<3 where x + dx < to { luma[y * w + x + dx] = 220 }; x += 5 } }
    }

    func testScrollingTextOnBlackIsCredits() {
        let g = grid { luma, w, h in self.textRows(&luma, w, h, rows: [10, 14, 18, 22, 30, 34]) }
        XCTAssertTrue(CreditsFrame.looksLikeCredits(g))
    }

    func testPlainBlackIsNotCredits() {
        XCTAssertFalse(CreditsFrame.looksLikeCredits(grid { _, _, _ in }))
    }

    func testBrightSceneIsNotCredits() {
        let g = grid { luma, w, h in for i in luma.indices { luma[i] = UInt8(100 + (i % 7) * 15) } }
        XCTAssertFalse(CreditsFrame.looksLikeCredits(g))
    }

    func testDarkSceneWithSoftShapesIsNotCredits() {
        // A dim room: broad soft gradients, few edges per row.
        let g = grid { luma, w, h in
            for y in 0..<h { for x in 0..<w { luma[y * w + x] = x > w / 2 && y > h / 3 ? 150 : 20 } }
        }
        XCTAssertFalse(CreditsFrame.looksLikeCredits(g))
    }

    func testOneLineOfTextIsNotEnough() {
        let g = grid { luma, w, h in self.textRows(&luma, w, h, rows: [27]) }
        XCTAssertFalse(CreditsFrame.looksLikeCredits(g))
    }

    func testClassifierReadsACGImage() {
        let w = 320, h = 180
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in stride(from: 40, to: 140, by: 12) { var x = 60; while x < 260 { for dx in 0..<8 { pixels[y * w + x + dx] = 230; pixels[(y + 1) * w + x + dx] = 230 }; x += 16 } }
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let image = ctx.makeImage()!
        XCTAssertTrue(CreditsFrame.looksLikeCredits(image))
    }

    // MARK: The scan

    func testScanFindsTheFirstSustainedRun() {
        var samples: [CreditsScan.Sample] = []
        for t in stride(from: 2300.0, to: 2600.0, by: 5) { samples.append(.init(time: t, credits: t >= 2520)) }
        XCTAssertEqual(CreditsScan.start(in: samples), 2520)
    }

    func testScanIgnoresAShortFadeInTheScene() {
        var samples: [CreditsScan.Sample] = []
        for t in stride(from: 2300.0, to: 2600.0, by: 5) { samples.append(.init(time: t, credits: t == 2400 || t == 2405 || t >= 2520)) }
        XCTAssertEqual(CreditsScan.start(in: samples), 2520)
    }

    func testScanSurvivesAStinger() {
        var samples: [CreditsScan.Sample] = []
        for t in stride(from: 2300.0, to: 2600.0, by: 5) { samples.append(.init(time: t, credits: t >= 2480 && !(t >= 2570 && t < 2590))) }
        XCTAssertEqual(CreditsScan.start(in: samples), 2480)
    }

    func testScanFindsNothingWithoutCredits() {
        let samples = stride(from: 2300.0, to: 2600.0, by: 5).map { CreditsScan.Sample(time: $0, credits: false) }
        XCTAssertNil(CreditsScan.start(in: samples))
    }

    func testWindowBounds() {
        XCTAssertEqual(CreditsScan.window(for: 600), 120)
        XCTAssertEqual(CreditsScan.window(for: 2600), 260)
        XCTAssertEqual(CreditsScan.window(for: 9000), 480)
    }
}
