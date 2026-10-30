#if DEBUG
import Foundation
import Playback
import MediaCore

/// A debug hook for the frame grab: `reel://debug-grab?file=<path under Demo>&from=<seconds>`.
/// Takes ten frames a second apart from one open at 8×, then one precise thumbnail, and logs
/// how many came back and how bright they are, so the memory output can be checked on a simulator.
enum DebugGrab {
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
            Diagnostics.log("debug", "grab seek: \(one.map { "mean \(Int(FrameFingerprint($0)?.brightness ?? -1))" } ?? "nil") in \(String(format: "%.1f", Date().timeIntervalSince(t2)))s")
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
