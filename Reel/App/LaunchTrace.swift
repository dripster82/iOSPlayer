import Foundation
import SwiftUI
import MediaCore
import Playback
import Sync
import UIKit

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

    /// Called from the first view's `onAppear`, with the app's state: a launch that iOS made in the
    /// background (a background task, a push, prewarming) runs starved of CPU and with its timers
    /// held, and its splash is still up when the viewer opens it.
    static func firstFrame(state: UIApplication.State) {
        let report: String? = lock.withLock {
            guard firstFrameAt == nil else { return nil }
            firstFrameAt = Date()
            let where_ = state == .active ? "" : state == .background ? " (in the background)" : " (inactive)"
            return "launch: first frame after \(String(format: "%.2f", firstFrameAt!.timeIntervalSince(began)))s\(where_)"
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
            let due = Date().addingTimeInterval(seconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                let stuck: String? = lock.withLock {
                    guard readyAt == nil else { return nil }
                    let frame = firstFrameAt == nil ? "no first frame" : "first frame drawn, not ready"
                    // This timer runs off the main thread: when it is itself late, the process was
                    // starved or suspended, and the main thread was not necessarily blocked.
                    let late = Date().timeIntervalSince(due)
                    let starved = late > 1 ? " (this timer fired \(String(format: "%.1f", late))s late: the process was starved or suspended)" : ""
                    return "launch: \(frame) after \(Int(seconds))s; still in \"\(current)\" for \(String(format: "%.1f", Date().timeIntervalSince(currentBegan)))s\(starved)"
                }
                if let stuck { Diagnostics.log("app", stuck) }
            }
        }
    }
}

/// The part of launch that runs after the first frame. Behind the splash, with its status line:
/// only VLC's library, which is local and which the first play needs. Nothing to do with the
/// network or iCloud gates the splash: sync starts once Home is up, and the viewer never waits for
/// it, so an iPad used offline, or one still settling after a boot, comes up just the same. Every
/// step yields to SwiftUI first, so the line naming it is on screen before the step can block.
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
        LaunchTrace.step("ready")
        withAnimation(.easeOut(duration: 0.25)) { ready = true }
        LaunchTrace.ready()
        // After Home: work nobody is waiting for. The sync start is a CloudKit engine being made and
        // the pending rows counted, local and a fraction of a second; its traffic is asynchronous
        // and fails quietly offline. Timed, so a slow one is in the log.
        try? await Task.sleep(for: .seconds(1))
        let began = Date()
        sync.startIfEnabled(cloudContainerID: AppSettings.cloudContainerID)
        ShowMarkers.retryEarlySearchesOnce()
        let took = Date().timeIntervalSince(began)
        if took > 0.5 { Diagnostics.log("app", "launch: sync start and show marks took \(String(format: "%.1f", took))s after Home was up") }
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
