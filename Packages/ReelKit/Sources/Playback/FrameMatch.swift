import Foundation
import CoreGraphics

/// A frame reduced to a small grey grid, for telling whether two frames show the same picture.
/// Title sequences reuse the same footage every episode, so a few fingerprints taken where the
/// viewer marked the intro find that intro again in another episode, wherever its cold open put it.
public struct FrameFingerprint: Codable, Equatable, Sendable {
    public static let width = 32, height = 18
    public var luma: [UInt8]   // row-major, width × height

    public init(luma: [UInt8]) { self.luma = luma }

    // Stored as bytes (base64 in JSON): a few hundred prints per show must stay small enough to
    // sync. Earlier builds wrote the array of numbers, which still reads.
    private enum Keys: String, CodingKey { case luma, bytes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let data = try c.decodeIfPresent(Data.self, forKey: .bytes) { luma = [UInt8](data) }
        else { luma = try c.decode([UInt8].self, forKey: .luma) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(Data(luma), forKey: .bytes)
    }

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

    /// Mean grey level: how much picture there is to compare.
    public var brightness: Double { luma.isEmpty ? 0 : Double(luma.reduce(0) { $0 + Int($1) }) / Double(luma.count) }

    /// Normalised correlation, −1…1: 1 is the same picture whatever its overall brightness or
    /// contrast (two encodes of the same titles differ in levels); unrelated pictures sit near 0,
    /// and two credits cards with names in different places likewise.
    public func similarity(to other: FrameFingerprint) -> Double {
        guard luma.count == other.luma.count, !luma.isEmpty else { return 0 }
        let n = Double(luma.count)
        let ma = brightness, mb = other.brightness
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<luma.count {
            let a = Double(luma[i]) - ma, b = Double(other.luma[i]) - mb
            cov += a * b; va += a * a; vb += b * b
        }
        guard va > n * 4, vb > n * 4 else { return 0 }   // a flat frame correlates with nothing
        return cov / (va.squareRoot() * vb.squareRoot())
    }
}

/// Finds a marked intro in another episode. The marks give `count` fingerprints `spacing` seconds
/// apart from the intro's start; a scan of the episode's opening minutes supplies samples, and the
/// best sample that matches one of the fingerprints places the start.
public enum IntroLocator {
    /// Seconds between the fingerprints taken from a marked intro whose length is known: four a
    /// second over the whole of it. Title sequences cut fast (frames a second apart differ by 40–80
    /// grey levels), so a sample from another episode must land within an eighth of a second of a
    /// print to be recognised. The frames come off the decoder anyway; keeping more costs nothing.
    public static let spacing: TimeInterval = 0.25
    /// Spacing when only the start is marked (the length is not known yet): 2 s over `count` frames.
    public static let provisionalSpacing: TimeInterval = 2
    public static let count = 20
    /// The most prints a show keeps: a hundred seconds of titles at four a second.
    public static let maxCount = 400
    /// Coarse scan step for a set of prints: two seconds short of the span they cover, so one
    /// sample per step is enough to land in the intro, and never under 8 s. Every frame of the
    /// scan is an open of the file over the share, seconds each, so the span sets the pace.
    public static func coarseStep(forPrints n: Int, spacing: TimeInterval) -> TimeInterval { max(8, TimeInterval(n - 1) * spacing - 2) }
    /// Mean grey difference below which two frames are taken to be the same picture. Frames a second
    /// apart in the same sequence score 5–20; frames from different scenes score 40 and up.
    public static let threshold: Double = 24

    /// The difference two frames may have and still be the same picture: the fixed threshold, or
    /// half the brighter frame's mean level when that is less. Two credits cards, names on black,
    /// differ by less than the threshold simply because both are mostly black; against their own
    /// brightness (a mean of 15 or so) a different card is still far apart and the same card close.
    public static func allowance(_ a: FrameFingerprint, _ b: FrameFingerprint) -> Double {
        min(threshold, 0.5 * max(a.brightness, b.brightness))
    }

    public struct Sample: Sendable { public var time: TimeInterval; public var print: FrameFingerprint; public init(time: TimeInterval, print: FrameFingerprint) { self.time = time; self.print = print } }

    /// Correlation at or above which two frames are the same picture. Frames an eighth of a second
    /// apart in the same sequence score 0.9 and up; different pictures score under 0.5.
    public static let minimumSimilarity: Double = 0.8

    /// The fingerprint most like `sample`, with its correlation.
    public static func nearest(_ sample: FrameFingerprint, in targets: [FrameFingerprint]) -> (index: Int, similarity: Double)? {
        var best: (Int, Double)?
        for (i, t) in targets.enumerated() where !t.isFlat {
            let s = sample.similarity(to: t)
            if best == nil || s > best!.1 { best = (i, s) }
        }
        return best
    }

    /// Whether `sample` shows the same picture as one of the fingerprints.
    public static func matches(_ sample: FrameFingerprint, in targets: [FrameFingerprint]) -> (index: Int, similarity: Double)? {
        guard let (i, s) = nearest(sample, in: targets), s >= minimumSimilarity else { return nil }
        return (i, s)
    }

    /// Where the intro starts, from coarse samples: the sample closest to a fingerprint, when it
    /// is close enough, shifted back by that fingerprint's offset from the start.
    public static func estimateStart(samples: [Sample], targets: [FrameFingerprint], spacing: TimeInterval = spacing) -> TimeInterval? {
        var best: (time: TimeInterval, similarity: Double)?
        for s in samples {
            guard let (i, sim) = matches(s.print, in: targets) else { continue }
            let start = max(0, s.time - TimeInterval(i) * spacing)
            if best == nil || sim > best!.similarity { best = (start, sim) }
        }
        return best?.time
    }
}
