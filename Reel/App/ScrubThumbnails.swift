import Foundation
import UIKit
import MediaCore
import VLCKit

/// Preview frames for the scrubber: one per 20 s of runtime (at least 9, at most 150), made with
/// VLC's thumbnailer a minute into a play (so they never compete with the opening buffer) and kept
/// in Caches/scrub-v3/<item>/. Each frame is a separate open of the stream, a second or two over
/// SMB, so they are made one at a time, coarse first (every ninth, then the gaps) so the scrubber
/// is useful within seconds and exact to the minute once the pass is done.
///
/// The thumbnailer's own `snapshotPosition` is a seek issued as playback starts, which libvlc 4
/// drops (the engine's resume has the same fight), so every frame came out as the first picture.
/// Each media is opened with `:start-time` instead, so its position zero *is* the wanted time.
@MainActor
final class ScrubThumbnails: ObservableObject {
    static let shared = ScrubThumbnails()

    private var memory: [String: [Int: UIImage]] = [:]
    private var counts: [String: Int] = [:]
    private var inProgress: Set<String> = []
    @Published private(set) var version = 0

    /// How many frames a title of this length gets: one every 20 s, 9 to 150 (so a two-hour film
    /// gets one every 48 s). Holding the finger still brings up the live preview for the exact frame.
    static func frameCount(for duration: TimeInterval) -> Int { min(150, max(9, Int(duration / 20))) }
    /// The order frames are made in: every ninth first, then the rest from the start.
    static func order(_ n: Int) -> [Int] {
        let stride = max(1, n / 9)
        let coarse = Array(Swift.stride(from: 0, to: n, by: stride))
        return coarse + (0..<n).filter { !coarse.contains($0) }
    }

    private static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Earlier caches: identical frames (before the start-time fix), then nine per title.
        for old in ["scrub", "scrub-v2"] { try? FileManager.default.removeItem(at: caches.appendingPathComponent(old, isDirectory: true)) }
        let dir = caches.appendingPathComponent("scrub-v4", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func folderName(_ key: String) -> String { String((key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key).prefix(180)) }
    private static func folder(_ key: String) -> URL { root.appendingPathComponent(folderName(key), isDirectory: true) }
    /// The one-a-minute cache from before: its frames stand in until the denser set is made.
    private static func legacyFolder(_ key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("scrub-v3", isDirectory: true).appendingPathComponent(folderName(key), isDirectory: true)
    }
    /// Titles whose frames in memory are the old coarse set: shown, but every index is still to be made.
    private var legacy: Set<String> = []

    /// The cached frame nearest to `fraction` (0…1), or nil while none exist yet.
    func image(for key: String, fraction: Double) -> UIImage? {
        if memory[key] == nil { load(key) }
        guard let frames = memory[key], !frames.isEmpty, let n = counts[key], n > 0 else { return nil }
        let wanted = min(n - 1, max(0, Int(fraction * Double(n))))
        let nearest = frames.keys.min { abs($0 - wanted) < abs($1 - wanted) }!
        return frames[nearest]
    }

    func hasFrames(for key: String) -> Bool { image(for: key, fraction: 0.5) != nil }

    /// Makes whatever frames are missing. Safe to call repeatedly. `duration` is the title's length,
    /// which the player knows by the time this is called; without it no frame can be placed.
    func ensure(key: String, url: URL, duration: TimeInterval) {
        guard duration > 0, !inProgress.contains(key) else { return }
        if memory[key] == nil { load(key) }
        var n = counts[key] ?? Self.frameCount(for: duration)
        if legacy.contains(key), let old = memory[key], let oldN = counts[key], oldN > 0 {
            // Spread the coarse frames over the new index space so they keep showing while the
            // real ones replace them one by one.
            n = Self.frameCount(for: duration)
            var spread: [Int: UIImage] = [:]
            for i in 0..<n { let fraction = (Double(i) + 0.5) / Double(n); let oldIndex = min(oldN - 1, max(0, Int(fraction * Double(oldN)))); if let img = old[oldIndex] { spread[i] = img } }
            memory[key] = spread
        }
        counts[key] = n
        let have = legacy.contains(key) ? Set<Int>() : Set(memory[key]?.keys ?? [:].keys)
        let missing = Self.order(n).filter { !have.contains($0) }
        guard !missing.isEmpty else { return }
        inProgress.insert(key)
        Task {
            defer { inProgress.remove(key) }
            let dir = Self.folder(key)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "\(n)".write(to: dir.appendingPathComponent("count.txt"), atomically: true, encoding: .utf8)
            var made = 0
            for i in missing {
                // Stop (and pick up next play) if the device heated up or went to Low Power Mode meanwhile.
                guard DeviceConditions.allowsBackgroundWork else { break }
                let at = (Double(i) + 0.5) / Double(n) * duration
                guard let image = await Self.frame(url: url, at: at) else { continue }
                let ui = UIImage(cgImage: image)
                if let data = ui.jpegData(compressionQuality: 0.7) { try? data.write(to: dir.appendingPathComponent("\(i).jpg")) }
                memory[key, default: [:]][i] = ui
                made += 1
                version += 1
            }
            if made == missing.count { legacy.remove(key) }
            Diagnostics.log("player", "scrub thumbnails for \(key.prefix(40)): \(made) of \(missing.count) made (\(n) per title)")
        }
    }

    private func load(_ key: String) {
        func read(_ dir: URL) -> (Int, [Int: UIImage]) {
            let n = Int((try? String(contentsOf: dir.appendingPathComponent("count.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            var out: [Int: UIImage] = [:]
            for i in 0..<max(0, n) { if let img = UIImage(contentsOfFile: dir.appendingPathComponent("\(i).jpg").path) { out[i] = img } }
            return (n, out)
        }
        var (n, out) = read(Self.folder(key))
        if out.isEmpty {
            let (oldN, old) = read(Self.legacyFolder(key))
            if !old.isEmpty { n = oldN; out = old; legacy.insert(key) }
        }
        if n > 0 { counts[key] = n }
        memory[key] = out
    }

    /// One frame at `seconds`, through VLCMediaThumbnailer and its delegate.
    private static func frame(url: URL, at seconds: TimeInterval) async -> CGImage? {
        guard let media = VLCMedia(url: url) else { return nil }
        media.addOption(":start-time=\(Int(seconds))")
        media.addOption(":no-audio")
        media.addOption(":network-caching=500")
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let job = ThumbJob(continuation: continuation)
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: job)
            thumbnailer.snapshotPosition = 0
            thumbnailer.thumbnailWidth = 320
            thumbnailer.thumbnailHeight = 180
            // The thumbnailer's delegate is weak, so the job must be held here until it reports.
            job.thumbnailer = thumbnailer
            jobs.insert(job)
            thumbnailer.fetchThumbnail()
        }
    }
    private static var jobs = Set<ThumbJob>()

    private final class ThumbJob: NSObject, VLCMediaThumbnailerDelegate {
        var thumbnailer: VLCMediaThumbnailer?
        private var continuation: CheckedContinuation<CGImage?, Never>?
        init(continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
        func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) { finish(nil) }
        func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) { finish(thumbnail) }
        private func finish(_ image: CGImage?) {
            continuation?.resume(returning: image)
            continuation = nil
            thumbnailer = nil
            Task { @MainActor in ScrubThumbnails.jobs.remove(self) }
        }
    }
}
