import Foundation
import UIKit
import MediaCore
import VLCKit

/// Preview frames for the scrubber: ten frames per title at 5 %, 15 %… 95 %, made with VLC's
/// thumbnailer twenty seconds into a play (so they never compete with the opening buffer) and kept
/// in Caches/scrub/<item>/. Each frame is a separate open-and-seek of the stream, a second or two
/// over SMB, so they are made one at a time and only once.
@MainActor
final class ScrubThumbnails: ObservableObject {
    static let shared = ScrubThumbnails()
    static let fractions: [Double] = stride(from: 0.05, through: 0.95, by: 0.1).map { $0 }

    private var memory: [String: [Int: UIImage]] = [:]
    private var inProgress: Set<String> = []
    @Published private(set) var version = 0

    private static var root: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("scrub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func folder(_ key: String) -> URL {
        root.appendingPathComponent(String((key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key).prefix(180)), isDirectory: true)
    }

    /// The cached frame nearest to `fraction` (0…1), or nil while none exist yet.
    func image(for key: String, fraction: Double) -> UIImage? {
        if memory[key] == nil { memory[key] = loadFromDisk(key) }
        guard let frames = memory[key], !frames.isEmpty else { return nil }
        let wanted = Int((fraction * 10).rounded(.down))
        let nearest = frames.keys.min { abs($0 - wanted) < abs($1 - wanted) }!
        return frames[nearest]
    }

    func hasFrames(for key: String) -> Bool { image(for: key, fraction: 0.5) != nil }

    /// Makes whatever frames are missing. Safe to call repeatedly.
    func ensure(key: String, url: URL) {
        guard !inProgress.contains(key) else { return }
        if memory[key] == nil { memory[key] = loadFromDisk(key) }
        let have = Set(memory[key]?.keys ?? [:].keys)
        let missing = Self.fractions.indices.filter { !have.contains($0) }
        guard !missing.isEmpty else { return }
        inProgress.insert(key)
        Task {
            defer { inProgress.remove(key) }
            let dir = Self.folder(key)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var made = 0
            for i in missing {
                guard let image = await Self.frame(url: url, position: Float(Self.fractions[i])) else { continue }
                let ui = UIImage(cgImage: image)
                if let data = ui.jpegData(compressionQuality: 0.7) { try? data.write(to: dir.appendingPathComponent("\(i).jpg")) }
                memory[key, default: [:]][i] = ui
                made += 1
                version += 1
            }
            Diagnostics.log("player", "scrub thumbnails for \(key.prefix(40)): \(made) of \(missing.count) made")
        }
    }

    private func loadFromDisk(_ key: String) -> [Int: UIImage] {
        let dir = Self.folder(key)
        var out: [Int: UIImage] = [:]
        for i in Self.fractions.indices {
            if let img = UIImage(contentsOfFile: dir.appendingPathComponent("\(i).jpg").path) { out[i] = img }
        }
        return out
    }

    /// One frame at `position` (0…1), through VLCMediaThumbnailer and its delegate.
    private static func frame(url: URL, position: Float) async -> CGImage? {
        guard let media = VLCMedia(url: url) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let job = ThumbJob(continuation: continuation)
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: job)
            thumbnailer.snapshotPosition = position
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
