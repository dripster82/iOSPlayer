import Foundation
import CoreGraphics

/// Tells end credits from the rest of an episode by what they look like: lines of light text on a
/// dark background, held for a while. A single frame is judged by `CreditsFrame`; a run of samples
/// over the last stretch of the file is turned into a start time by `CreditsScan`. Neither opens a
/// file; the app's thumbnailer supplies the frames.
public enum CreditsFrame {
    /// The frame reduced to a small grey grid: cheap to classify and to make in a test.
    struct Grid {
        let width: Int, height: Int
        let luma: [UInt8]   // row-major
        subscript(x: Int, y: Int) -> Int { Int(luma[y * width + x]) }
    }

    static let gridWidth = 96, gridHeight = 54

    /// Whether the frame looks like credits: at least three quarters of it dark, and at least two
    /// rows of the kind text makes (a modest share of bright pixels with many dark-to-light edges
    /// along the row). A dark scene has few edges; a bright one is not mostly dark; a plain black
    /// frame has no rows at all.
    public static func looksLikeCredits(_ image: CGImage) -> Bool {
        guard let grid = grid(of: image) else { return false }
        return looksLikeCredits(grid)
    }

    static func looksLikeCredits(_ g: Grid) -> Bool {
        let total = g.width * g.height
        var dark = 0
        for v in g.luma where v < 48 { dark += 1 }
        guard Double(dark) / Double(total) >= 0.72 else { return false }
        var textRows = 0
        for y in 0..<g.height {
            var bright = 0, edges = 0, wasBright = false
            for x in 0..<g.width {
                let isBright = g[x, y] >= 120
                if isBright { bright += 1 }
                if isBright != wasBright { edges += 1; wasBright = isBright }
            }
            let share = Double(bright) / Double(g.width)
            if share >= 0.03, share <= 0.45, edges >= 6 { textRows += 1 }
        }
        return textRows >= 2
    }

    static func grid(of image: CGImage) -> Grid? {
        let w = gridWidth, h = gridHeight
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Grid(width: w, height: h, luma: pixels)
    }
}

public enum CreditsScan {
    public struct Sample: Equatable, Sendable { public var time: TimeInterval; public var credits: Bool; public init(time: TimeInterval, credits: Bool) { self.time = time; self.credits = credits } }

    /// How far back from the end to look: a tenth of the runtime, between two and eight minutes.
    public static func window(for duration: TimeInterval) -> TimeInterval { min(480, max(120, duration * 0.1)) }
    /// Seconds between samples.
    public static let step: TimeInterval = 5

    /// The credits' start among the samples (sorted by time), or nil. The start is the first sample of
    /// the earliest run of at least three credits-like samples after which credits-like samples stay in
    /// the majority to the end: a title card or a fade in the final scene is too short to count, and a
    /// scene that follows the credits (a stinger) does not undo them.
    public static func start(in samples: [Sample]) -> TimeInterval? {
        guard samples.count >= 3 else { return nil }
        for i in 0..<(samples.count - 2) where samples[i].credits && samples[i + 1].credits && samples[i + 2].credits {
            let rest = samples[i...]
            let share = Double(rest.filter(\.credits).count) / Double(rest.count)
            if share >= 0.6 { return samples[i].time }
        }
        return nil
    }
}
