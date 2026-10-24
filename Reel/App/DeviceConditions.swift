import Foundation
import Network

/// Thermal state, Low Power Mode and the network path, for work that can wait: scrubber thumbnails,
/// artwork prefetches, watchdog cadence. Playback itself never consults this.
enum DeviceConditions {
    /// False while the device is seriously hot or in Low Power Mode.
    static var allowsBackgroundWork: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && !isHot
    }
    static var isHot: Bool {
        switch ProcessInfo.processInfo.thermalState { case .serious, .critical: true; default: false }
    }
    static var summary: String {
        var parts: [String] = []
        if ProcessInfo.processInfo.isLowPowerModeEnabled { parts.append("low power") }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: break
        case .fair: parts.append("thermal fair")
        case .serious: parts.append("thermal serious")
        case .critical: parts.append("thermal critical")
        @unknown default: break
        }
        return parts.isEmpty ? "normal" : parts.joined(separator: ", ")
    }

    /// True on cellular or a personal hotspot.
    static func isOnExpensivePath() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            var done = false
            monitor.pathUpdateHandler = { path in
                guard !done else { return }
                done = true
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}
