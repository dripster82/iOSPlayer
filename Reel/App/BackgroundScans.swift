import Foundation
import BackgroundTasks
import Network
import Library

/// Continues scanning and TMDb matching after the user leaves the app.
///
/// Two layers: `LibraryStore.scan` already holds a `beginBackgroundTask` assertion, which buys a few
/// minutes. For anything longer this schedules a `BGProcessingTask`, which iOS runs when the phone is
/// idle (typically charging, on Wi-Fi) and which re-runs `scanAll` until the library is matched.
@MainActor
enum BackgroundScans {
    static let identifier = "uk.co.ketelle.reel.scan"

    /// Call before `application(_:didFinishLaunching)` returns, i.e. from `ReelApp.init`.
    static func register(library: LibraryStore, settings: AppSettings) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in await run(task, library: library, settings: settings) }
        }
    }

    static func schedule(after seconds: TimeInterval) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // Simulator and some builds refuse background tasks; nothing to do but try again next time.
        }
    }

    private static func run(_ task: BGProcessingTask, library: LibraryStore, settings: AppSettings) async {
        task.expirationHandler = {
            Task { @MainActor in library.cancelScans() }
        }
        if !settings.scanOnCellular, await currentPathIsExpensive() {
            task.setTaskCompleted(success: false)
            schedule(after: 15 * 60)
            return
        }
        library.scanAll(tmdb: settings.tmdb)
        await library.waitForScans()
        let finished = library.unmatchedFileCount() == 0
        task.setTaskCompleted(success: true)
        // Come back soon if there is still work, otherwise keep the daily refresh going.
        schedule(after: finished ? 24 * 3600 : 5 * 60)
    }

    /// True on cellular or a personal hotspot, where the user may not want a 4,000-request match run.
    private static func currentPathIsExpensive() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.isExpensive)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}
