import Foundation
import UIKit
import MediaCore
import VLCKit
import Playback

/// Preview frames for the scrubber: one per 20 s of runtime (at least 9, at most 150), made with
/// VLC's thumbnailer a minute into a play (so they never compete with the opening buffer) and kept
/// in Caches/scrub-v6/<item>/. Each frame is a separate open of the stream, a second or two over
/// SMB, so they are made one at a time, coarse first (every ninth, then the gaps) so the scrubber
/// is useful within seconds and exact to the minute once the pass is done.
///
/// Each media is opened with `:start-time` at the wanted time. libvlc 4 makes positions relative
/// to that range, and VLCKit's thumbnailer reads a `snapshotPosition` of 0 as unset and uses 0.3,
/// which put every frame 30% of the way from its start time to the end of the file (the v5 cache);
/// a hair above 0 keeps the snapshot at the start time.
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
    /// The order frames are made in: every ninth first, so the whole bar has something within a
    /// minute; then the rest ahead of the playhead in order, where the next scrub goes, and
    /// last the part behind it, nearest first (playback itself fills that part for free).
    static func order(_ n: Int, around current: Int = 0) -> [Int] {
        let stride = max(1, n / 9)
        let coarse = Array(Swift.stride(from: 0, to: n, by: stride))
        let rest = (0..<n).filter { !coarse.contains($0) }
        let cur = min(max(0, current), max(0, n - 1))
        return coarse + rest.filter { $0 >= cur } + rest.filter { $0 < cur }.reversed()
    }

    /// The title playing now. A job for any other title stops after the frame it is on: a title
    /// skipped past in seconds used to get its whole pass, slowing the one on screen to a crawl.
    private var focused: String?
    func focus(_ key: String?) {
        if let old = focused, old != key, let c = captured[old], c > 0 {
            Diagnostics.log("player", "scrub frames for \(old.prefix(40)): \(c) taken from playback")
            captured[old] = nil
        }
        focused = key
    }
    private var capturing: Set<String> = []
    private var captured: [String: Int] = [:]
    private var snapshotWarned: Set<String> = []

    /// A frame from the picture on screen: as playback passes the middle of a strip slot that has
    /// no frame yet, the engine writes a snapshot, which costs nothing over the share. The
    /// background pass is then left with only the parts not yet watched. Only software-decoded
    /// titles get these: VLC cannot convert a hardware surface for a snapshot ("Failed to convert
    /// image for snapshot"), so after the first miss a title is left to the thumbnailer.
    func capture(key: String, time: TimeInterval, duration: TimeInterval, engine: VLCPlaybackEngine) {
        guard duration > 0, !capturing.contains(key), !snapshotWarned.contains(key) else { return }
        if memory[key] == nil { load(key) }
        let n = counts[key] ?? Self.frameCount(for: duration)
        counts[key] = n
        let i = min(n - 1, max(0, Int(time / duration * Double(n))))
        let centre = (Double(i) + 0.5) / Double(n) * duration
        // Just past the slot's middle, so the frame is within a couple of seconds of where the strip says it is.
        guard time >= centre, time < centre + 2.5, legacy.contains(key) || memory[key]?[i] == nil else { return }
        let dir = Self.folder(key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let countFile = dir.appendingPathComponent("count.txt")
        if !FileManager.default.fileExists(atPath: countFile.path) { try? "\(n)".write(to: countFile, atomically: true, encoding: .utf8) }
        let png = dir.appendingPathComponent("\(i).snapshot.png")
        try? FileManager.default.removeItem(at: png)
        capturing.insert(key)
        engine.saveSnapshot(to: png.path, width: 320)
        Task {
            defer { capturing.remove(key); try? FileManager.default.removeItem(at: png) }
            var waited = 0
            while !FileManager.default.fileExists(atPath: png.path), waited < 30 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
            try? await Task.sleep(for: .milliseconds(150))   // the write may still be finishing when the file appears
            guard let ui = UIImage(contentsOfFile: png.path), let cg = ui.cgImage, Self.looksLikeAPicture(cg) else {
                if waited >= 30, snapshotWarned.insert(key).inserted { Diagnostics.log("player", "scrub snapshot for \(key.prefix(40)) never arrived; the strip relies on the thumbnailer") }
                return
            }
            if let data = ui.jpegData(compressionQuality: 0.7) { try? data.write(to: dir.appendingPathComponent("\(i).jpg")) }
            memory[key, default: [:]][i] = ui
            captured[key, default: 0] += 1
            version += 1
        }
    }

    private static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Earlier caches: identical frames (before the start-time fix), then nine per title; scrub-v4
        // held frames the hardware decoder got wrong (black, green); v3 and v5 held frames tens of
        // seconds late (the thumbnailer's 0.3 default position inside the start-time range).
        for old in ["scrub", "scrub-v2", "scrub-v3", "scrub-v4", "scrub-v5"] { try? FileManager.default.removeItem(at: caches.appendingPathComponent(old, isDirectory: true)) }
        let dir = caches.appendingPathComponent("scrub-v6", isDirectory: true)
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
    func ensure(key: String, url: URL, duration: TimeInterval, position: TimeInterval = 0, softwareDecoding: Bool = false) {
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
        let missing = Self.order(n, around: Int(position / duration * Double(n))).filter { !have.contains($0) }
        guard !missing.isEmpty else { return }
        inProgress.insert(key)
        Task {
            defer { inProgress.remove(key) }
            let dir = Self.folder(key)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "\(n)".write(to: dir.appendingPathComponent("count.txt"), atomically: true, encoding: .utf8)
            var made = 0, stopped: String?
            for i in missing {
                // Stop (and pick up next play) if the device heated up or went to Low Power Mode
                // meanwhile, or another title took the screen.
                if !DeviceConditions.allowsBackgroundWork { stopped = DeviceConditions.summary; break }
                if let f = focused, f != key { stopped = "another title playing"; break }
                // Playback may have captured this one since the list was made.
                if !legacy.contains(key), memory[key]?[i] != nil { continue }
                let at = (Double(i) + 0.5) / Double(n) * duration
                guard let image = await Self.frame(url: url, at: at, softwareDecoding: softwareDecoding), Self.looksLikeAPicture(image) else { continue }
                let ui = UIImage(cgImage: image)
                if let data = ui.jpegData(compressionQuality: 0.7) { try? data.write(to: dir.appendingPathComponent("\(i).jpg")) }
                memory[key, default: [:]][i] = ui
                made += 1
                version += 1
            }
            if stopped == nil { legacy.remove(key) }
            Diagnostics.log("player", "scrub thumbnails for \(key.prefix(40)): \(made) of \(missing.count) made (\(n) per title)\(stopped.map { "; stopped: \($0)" } ?? "")")
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

    /// One frame at `seconds`. `precise` decodes up to the frame itself (libvlc's precise seek) for
    /// the fingerprints, which must line up between episodes; the scrubber's own frames take the
    /// keyframe before, which VLCMediaThumbnailer hands back faster.
    static func frame(url: URL, at seconds: TimeInterval, softwareDecoding: Bool, precise: Bool = false) async -> CGImage? {
        // libvlc's own thumbnailer, at an absolute time. VLCKit's VLCMediaThumbnailer below is the
        // fallback where the shim is not built: it places its frame relative to the start-time
        // range (30% of the way to the end), so its frames come out tens of seconds late.
        if PreciseThumbnail.isAvailable { return await PreciseThumbnail.frame(url: url, at: seconds, softwareDecoding: softwareDecoding, fast: !precise) }
        guard let media = VLCMedia(url: url) else { return nil }
        media.addOption(":start-time=\(Int(seconds))")
        media.addOption(":no-audio")
        media.addOption(":network-caching=500")
        if softwareDecoding { media.addOption(":avcodec-hw=none") }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let job = ThumbJob(continuation: continuation)
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: job)
            // Not 0: VLCKit reads 0 as "unset" and falls back to its default of 0.3, and with a
            // start-time that is 30% of the way from the start time to the end of the file, so
            // every frame in the strip came out tens of seconds late. A hair above 0 lands at the start time.
            thumbnailer.snapshotPosition = 0.001
            thumbnailer.thumbnailWidth = 320
            thumbnailer.thumbnailHeight = 180
            // The thumbnailer's delegate is weak, so the job must be held here until it reports.
            job.thumbnailer = thumbnailer
            jobs.insert(job)
            thumbnailer.fetchThumbnail()
        }
    }
    private static var jobs = Set<ThumbJob>()

    /// A frame the decoder got wrong is a flat colour (black, or green from a bad hardware decode).
    /// A sample of pixels has to differ for the frame to be kept.
    static func looksLikeAPicture(_ image: CGImage) -> Bool {
        let w = 16, h = 9
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lo = [255, 255, 255], hi = [0, 0, 0]
        for p in 0..<(w * h) { for c in 0..<3 { let v = Int(pixels[p * 4 + c]); lo[c] = min(lo[c], v); hi[c] = max(hi[c], v) } }
        return (0..<3).contains { hi[$0] - lo[$0] > 24 }
    }

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
