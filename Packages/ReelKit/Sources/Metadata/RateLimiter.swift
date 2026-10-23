import Foundation

/// Sliding-window limiter. TMDb allows roughly 40 requests per 10 seconds; we stay under it.
public actor RateLimiter {
    private let limit: Int
    private let window: TimeInterval
    private var timestamps: [Date] = []

    public init(limit: Int = 35, window: TimeInterval = 10) {
        self.limit = limit
        self.window = window
    }

    public func acquire() async {
        while true {
            let now = Date()
            timestamps.removeAll { now.timeIntervalSince($0) > window }
            if timestamps.count < limit {
                timestamps.append(now)
                return
            }
            let wait = window - now.timeIntervalSince(timestamps[0]) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, wait) * 1_000_000_000))
        }
    }
}
