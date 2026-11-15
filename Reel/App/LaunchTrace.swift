import Foundation
import MediaCore

/// What launch is doing, for the log. The iPad once came up to a white screen after a power-off
/// and on (15 Nov 2026), with nothing in the log at all: the launch screen stays up while the main
/// thread is busy in `ReelApp.init` or the first body, and nothing in that path logged. Each step
/// of the init is marked here; a timer off the main thread reports, at 5, 15 and 30 s, which step
/// the launch is still in if the first frame has not been drawn by then, and the first frame logs
/// how long each step took.
enum LaunchTrace {
    private static let lock = NSLock()
    private static let began = Date()
    private static var current = "start"
    private static var currentBegan = began
    private static var steps: [(String, TimeInterval)] = []
    private static var firstFrameAt: Date?

    static func step(_ name: String) {
        lock.withLock {
            let now = Date()
            steps.append((current, now.timeIntervalSince(currentBegan)))
            current = name; currentBegan = now
        }
    }

    /// Called once from the first view's `onAppear`.
    static func firstFrame() {
        let report: String? = lock.withLock {
            guard firstFrameAt == nil else { return nil }
            let now = Date()
            firstFrameAt = now
            steps.append((current, now.timeIntervalSince(currentBegan)))
            let slow = steps.filter { $0.1 >= 0.05 }.map { "\($0.0) \(String(format: "%.2f", $0.1))s" }
            return "launch: first frame after \(String(format: "%.2f", now.timeIntervalSince(began)))s" + (slow.isEmpty ? "" : " (\(slow.joined(separator: ", ")))")
        }
        if let report { Diagnostics.log("app", report) }
    }

    /// Started from `ReelApp.init`; harmless when the first frame comes in time.
    static func watch() {
        for seconds in [5.0, 15.0, 30.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                let stuck: String? = lock.withLock {
                    guard firstFrameAt == nil else { return nil }
                    return "launch: no first frame after \(Int(seconds))s; still in \"\(current)\" for \(String(format: "%.1f", Date().timeIntervalSince(currentBegan)))s"
                }
                if let stuck { Diagnostics.log("app", stuck) }
            }
        }
    }
}
