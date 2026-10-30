import Foundation
import CoreGraphics

/// A frame reduced to a small grey grid, for telling whether two frames show the same picture.
/// Title sequences reuse the same footage every episode, so a few fingerprints taken where the
/// viewer marked the intro find that intro again in another episode, wherever its cold open put it.
public struct FrameFingerprint: Codable, Equatable, Sendable {
    public static let width = 32, height = 18
    public var luma: [UInt8]   // row-major, width × height

    public init(luma: [UInt8]) { self.luma = luma }

    public init?(_ image: CGImage) {
        let w = Self.width, h = Self.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        luma = pixels
    }

    /// Mean absolute difference in grey level, 0 (identical) to 255.
    public func distance(to other: FrameFingerprint) -> Double {
        guard luma.count == other.luma.count, !luma.isEmpty else { return 255 }
        var sum = 0
        for i in 0..<luma.count { sum += abs(Int(luma[i]) - Int(other.luma[i])) }
        return Double(sum) / Double(luma.count)
    }

    /// A flat frame (black, a fade) matches every other flat frame; it is no use as a fingerprint.
    public var isFlat: Bool {
        guard let lo = luma.min(), let hi = luma.max() else { return true }
        return hi - lo < 24
    }
}

/// Finds a marked intro in another episode. The marks give `count` fingerprints `spacing` seconds
/// apart from the intro's start; a scan of the episode's opening minutes supplies samples, and the
/// best sample that matches one of the fingerprints places the start.
public enum IntroLocator {
    /// Seconds between the fingerprints taken from the marked intro.
    public static let spacing: TimeInterval = 2
    /// How many fingerprints: 20 cover the first 38 s of the intro, so a coarse scan every 36 s
    /// always lands within a second of one of them. Every frame of the scan is an open of the file
    /// over the share, seconds each, so the longer the span the sooner the intro is found.
    public static let count = 20
    /// Coarse scan step for a set of fingerprints: two seconds short of the span they cover, and
    /// never under 8 s (a set trimmed to a short intro still works, just slower).
    public static func coarseStep(forPrints n: Int) -> TimeInterval { max(8, TimeInterval(n - 2) * spacing) }
    public static var coarseStep: TimeInterval { coarseStep(forPrints: count) }
    /// Mean grey difference below which two frames are taken to be the same picture. Frames a second
    /// apart in the same sequence score 5–20; frames from different scenes score 40 and up.
    public static let threshold: Double = 24

    public struct Sample: Sendable { public var time: TimeInterval; public var print: FrameFingerprint; public init(time: TimeInterval, print: FrameFingerprint) { self.time = time; self.print = print } }

    /// The fingerprint nearest to `sample`, with its distance.
    public static func nearest(_ sample: FrameFingerprint, in targets: [FrameFingerprint]) -> (index: Int, distance: Double)? {
        var best: (Int, Double)?
        for (i, t) in targets.enumerated() where !t.isFlat {
            let d = sample.distance(to: t)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best
    }

    /// Where the intro starts, from coarse samples: the sample closest to a fingerprint, when it
    /// is close enough, shifted back by that fingerprint's offset from the start.
    public static func estimateStart(samples: [Sample], targets: [FrameFingerprint]) -> TimeInterval? {
        var best: (time: TimeInterval, distance: Double)?
        for s in samples {
            guard let (i, d) = nearest(s.print, in: targets), d < threshold else { continue }
            let start = max(0, s.time - TimeInterval(i) * spacing)
            if best == nil || d < best!.distance { best = (start, d) }
        }
        return best?.time
    }
}
