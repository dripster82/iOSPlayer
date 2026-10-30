#if DEBUG
import Foundation
import UIKit
import Playback
import MediaCore
import Library
import MediaSources

/// A debug hook for the frame grab: `reel://debug-grab?file=<path under Demo>&from=<seconds>`.
/// Takes ten frames a second apart from one open at 8×, then one precise thumbnail, and logs
/// how many came back and how bright they are, so the memory output can be checked on a simulator.
enum DebugGrab {
    /// `reel://debug-grab-current?from=195&count=40&spacing=1&seek=205,213,221`: frames from the last
    /// played file (its resolved URL, credentials included) by a run and by seeks, saved as JPEGs
    /// under Diagnostics/grab-run/, to see what the decoder gives at those times.
    @MainActor
    static func runCurrent(_ url: URL, player: PlayerCoordinator, library: LibraryStore) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ n: String) -> String? { comps?.queryItems?.first(where: { $0.name == n })?.value }
        let from = TimeInterval(q("from") ?? "") ?? 0, count = Int(q("count") ?? "") ?? 20, spacing = TimeInterval(q("spacing") ?? "") ?? 1
        let seeks = (q("seek") ?? "").split(separator: ",").compactMap { TimeInterval($0) }
        Task {
            // `item=<key>` resolves that title's file through the library; otherwise the last played URL.
            var target = player.lastPlaybackURL
            if let key = q("item"), let file = library.item(key)?.files.first { target = try? await library.playbackURL(for: file).0 }
            guard let target else { Diagnostics.log("debug", "grab-current: nothing to open"); return }
            await grab(target, from: from, count: count, spacing: spacing, seeks: seeks)
        }
    }

    @MainActor
    private static func grab(_ target: URL, from: TimeInterval, count: Int, spacing: TimeInterval, seeks: [TimeInterval]) async {
        let folder = Diagnostics.fileURL.deletingLastPathComponent().appendingPathComponent("grab-run", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let logURL = Diagnostics.fileURL.deletingLastPathComponent().appendingPathComponent("vlc.grab.log")
        try? FileManager.default.removeItem(at: logURL)
        FrameGrabber.setLogPath(logURL.path)
        Diagnostics.log("debug", "grab-current on \(Diagnostics.safe(target)) from \(Int(from))s, \(count) × \(spacing)s, seeks \(seeks)")
        do {
            let began = Date()
            guard let grabber = FrameGrabber(url: target) else { Diagnostics.log("debug", "grab session could not be made"); return }
            let frames = await grabber.frames(from: from, count: count, spacing: spacing)
            for f in frames { if let d = UIImage(cgImage: f.image).jpegData(compressionQuality: 0.8) { try? d.write(to: folder.appendingPathComponent(String(format: "run-%06.2fs.jpg", f.time))) } }
            Diagnostics.log("debug", "grab-current run: \(frames.count) frames in \(String(format: "%.1f", Date().timeIntervalSince(began)))s: " + frames.map { "\(Int($0.time))s mean \(Int(FrameFingerprint($0.image)?.brightness ?? -1))" }.joined(separator: ", "))
            for t in seeks {
                // A mini-run after the seek: do later frames settle to the right picture?
                let mini = await grabber.frames(from: t, count: 6, spacing: 0.5)
                Diagnostics.log("debug", "grab-current mini-run from \(Int(t))s: " + mini.map { "\(String(format: "%.1f", $0.time))s mean \(Int(FrameFingerprint($0.image)?.brightness ?? -1))" }.joined(separator: ", "))
                let t0 = Date()
                let got = await grabber.frame(at: t)
                if let got, let d = UIImage(cgImage: got.image).jpegData(compressionQuality: 0.8) { try? d.write(to: folder.appendingPathComponent(String(format: "seek-%06.2fs.jpg", t))) }
                Diagnostics.log("debug", "grab-current seek \(Int(t))s: \(got.map { "frame at \(String(format: "%.1f", $0.time))s mean \(Int(FrameFingerprint($0.image)?.brightness ?? -1))" } ?? "nil") in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            }
            await Task.detached { grabber.close() }.value
        }
    }

    @MainActor
    static func run(_ url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let file = comps?.queryItems?.first(where: { $0.name == "file" })?.value ?? "Films/Aurora Over the Fjord (2021).mp4"
        let from = TimeInterval(comps?.queryItems?.first(where: { $0.name == "from" })?.value ?? "") ?? 30
        guard let base = Bundle.main.resourceURL?.appendingPathComponent(DemoLibrary.folder, isDirectory: true) else { return }
        let target = base.appendingPathComponent(file)
        Diagnostics.log("debug", "grab test on \(file) from \(Int(from))s; exists \(FileManager.default.fileExists(atPath: target.path))")
        let logURL = Diagnostics.fileURL.deletingLastPathComponent().appendingPathComponent("vlc.grab.log")
        try? FileManager.default.removeItem(at: logURL)
        FrameGrabber.setLogPath(logURL.path)
        Task {
            let began = Date()
            guard let grabber = FrameGrabber(url: target) else { Diagnostics.log("debug", "grab session could not be made"); return }
            let frames = await grabber.frames(from: from, count: 10, spacing: 1)
            let prints = frames.map { ($0.time, FrameFingerprint($0.image)) }
            Diagnostics.log("debug", "grab run: \(frames.count) frames in \(String(format: "%.1f", Date().timeIntervalSince(began)))s: " + prints.map { "\(Int($0.0))s mean \($0.1.map { Int($0.brightness) } ?? -1)\($0.1?.isFlat == true ? " flat" : "")" }.joined(separator: ", "))
            let t2 = Date()
            let one = await grabber.frame(at: from + 20)
            Diagnostics.log("debug", "grab seek: \(one.map { "frame at \(String(format: "%.1f", $0.time))s mean \(Int(FrameFingerprint($0.image)?.brightness ?? -1))" } ?? "nil") in \(String(format: "%.1f", Date().timeIntervalSince(t2)))s")
            await Task.detached { grabber.close() }.value
            let t3 = Date()
            let thumb = await PreciseThumbnail.frame(url: target, at: from + 20)
            Diagnostics.log("debug", "precise thumbnail: \(thumb.map { "mean \(Int(FrameFingerprint($0)?.brightness ?? -1))" } ?? "nil") in \(String(format: "%.1f", Date().timeIntervalSince(t3)))s")
            let vlc = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            Diagnostics.log("debug", "vlc grab log (\(vlc.count) chars): " + vlc.split(separator: "\n").suffix(40).joined(separator: " | "))
        }
    }
}
#endif

#if DEBUG
/// A debug hook that lists a source folder into the log: `reel://debug-list?path=Torrents&depth=2`
/// (`source=<name>` picks a source; the first otherwise). For looking at how a library is laid out
/// without the NAS's credentials ever leaving the device.
@MainActor enum DebugList {
    static func run(_ url: URL, library: LibraryStore) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let path = q.first { $0.name == "path" }?.value ?? ""
        let depth = q.first { $0.name == "depth" }?.value.flatMap(Int.init) ?? 1
        let name = q.first { $0.name == "source" }?.value
        let sources = library.sources()
        guard let record = name.flatMap({ n in sources.first { $0.name.localizedCaseInsensitiveContains(n) } }) ?? sources.first else { Diagnostics.log("debug", "list: no source"); return }
        let config = record.config, id = record.id, sourceName = record.name
        Task.detached {
            let src = SourceFactory.make(config)
            do {
                try await src.connect(credentials: CredentialStore.shared.load(for: id))
                var lines: [String] = []
                func walk(_ p: String, _ level: Int) async throws {
                    let entries = try await src.list(p).sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
                    for e in entries where !(e.isDirectory && DirectoryEntry.isSystemFolder(e.name)) {
                        lines.append(String(repeating: "  ", count: level) + (e.isDirectory ? "[\(e.name)]" : "\(e.name) (\(e.size.map(MediaFormat.bytes) ?? "?"))"))
                        if e.isDirectory, level + 1 < depth { try await walk(e.relativePath, level + 1) }
                    }
                }
                try await walk(path, 0)
                await src.disconnect()
                Diagnostics.log("debug", "list \(sourceName):\(path) depth \(depth): \(lines.count) entries\n" + lines.joined(separator: "\n"))
            } catch { Diagnostics.log("debug", "list \(sourceName):\(path) failed: \(error.localizedDescription)") }
        }
    }
}
#endif
