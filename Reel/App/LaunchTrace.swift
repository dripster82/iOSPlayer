import Foundation
import SwiftUI
import MediaCore
import Playback
import Sync

/// What launch is doing, for the log. The iPad once came up to a white screen after a power-off
/// and on (15 Nov 2026), with nothing in the log at all: the launch screen stays up while the main
/// thread is busy before the first frame, and nothing in that path logged. `ReelApp.init` now does
/// only what is cheap and local, marking each step here; the slow services (VLC's plugins, CloudKit)
/// start after the first frame in `LaunchSequence`, behind a status line. A timer off the main
/// thread reports, at 5, 15 and 30 s, which step the launch is still in if it is not ready by then.
enum LaunchTrace {
    private static let lock = NSLock()
    private static let began = Date()
    private static var current = "start"
    private static var currentBegan = began
    private static var steps: [(String, TimeInterval)] = []
    private static var firstFrameAt: Date?
    private static var readyAt: Date?

    static func step(_ name: String) {
        lock.withLock {
            let now = Date()
            steps.append((current, now.timeIntervalSince(currentBegan)))
            current = name; currentBegan = now
        }
    }

    /// Called from the first view's `onAppear`.
    static func firstFrame() {
        let report: String? = lock.withLock {
            guard firstFrameAt == nil else { return nil }
            firstFrameAt = Date()
            return "launch: first frame after \(String(format: "%.2f", firstFrameAt!.timeIntervalSince(began)))s"
        }
        if let report { Diagnostics.log("app", report) }
    }

    /// Called when the launch sequence has finished; logs every step that took a noticeable time.
    static func ready() {
        let report: String? = lock.withLock {
            guard readyAt == nil else { return nil }
            let now = Date()
            readyAt = now
            steps.append((current, now.timeIntervalSince(currentBegan)))
            let slow = steps.filter { $0.1 >= 0.05 }.map { "\($0.0) \(String(format: "%.2f", $0.1))s" }
            return "launch: ready after \(String(format: "%.2f", now.timeIntervalSince(began)))s" + (slow.isEmpty ? "" : " (\(slow.joined(separator: ", ")))")
        }
        if let report { Diagnostics.log("app", report) }
    }

    /// Started from `ReelApp.init`; silent when launch finishes in time.
    static func watch() {
        for seconds in [5.0, 15.0, 30.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                let stuck: String? = lock.withLock {
                    guard readyAt == nil else { return nil }
                    let frame = firstFrameAt == nil ? "no first frame" : "first frame drawn, not ready"
                    return "launch: \(frame) after \(Int(seconds))s; still in \"\(current)\" for \(String(format: "%.1f", Date().timeIntervalSince(currentBegan)))s"
                }
                if let stuck { Diagnostics.log("app", stuck) }
            }
        }
    }
}

/// The part of launch that runs after the first frame: the services that can be slow to come up in
/// the first minutes after a boot, each behind a status line on the splash. Every step yields to
/// SwiftUI first, so the line naming it is on screen before the step can block the main thread.
@MainActor
final class LaunchSequence: ObservableObject {
    @Published private(set) var status = "Starting"
    @Published private(set) var ready = false

    func run(player: PlayerCoordinator, sync: SyncEngine) async {
        await step("Preparing the player") { player.engine.warmUp() }   // VLC's library and plugins
        #if canImport(VLCKit) && DEBUG
        await step("Opening the VLC log") {
            HLSRemuxer.enableVLCLog(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics/vlc.log"), level: 3)
        }
        #endif
        await step("Starting iCloud sync") { sync.startIfEnabled(cloudContainerID: AppSettings.cloudContainerID) }
        await step("Checking show marks") { ShowMarkers.retryEarlySearchesOnce() }
        LaunchTrace.step("ready")
        withAnimation(.easeOut(duration: 0.25)) { ready = true }
        LaunchTrace.ready()
    }

    private func step(_ name: String, _ work: () -> Void) async {
        status = name
        LaunchTrace.step(name)
        try? await Task.sleep(for: .milliseconds(40))   // a frame for the status line
        work()
    }
}

/// The splash over the first frame: the app's name, a spinner and what launch is doing.
struct LaunchView: View {
    @ObservedObject var launch: LaunchSequence
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Reel").font(.title2.bold())
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(launch.status + "…").font(.footnote).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }
}
