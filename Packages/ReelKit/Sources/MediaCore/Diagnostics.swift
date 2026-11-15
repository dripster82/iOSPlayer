import Foundation

/// A small on-device log of what the app did: player state changes, reconnects, source connections,
/// sync results and app lifecycle. Settings → Diagnostics shows it and can share the file.
///
/// It exists because the device's system log is not readable from a Mac without a wired debug
/// session, so "it just spun" was otherwise unanswerable. Never log credentials or full URLs with
/// user info; `safe(_:)` strips them.
public enum Diagnostics {
    public static let maxBytes = 1_000_000
    private static let queue = DispatchQueue(label: "reel.diagnostics", qos: .utility)
    private static var recentLines: [String] = []
    private static let recentLimit = 1000

    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reel.log")
    }
    private static var rotatedURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("reel.previous.log") }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// `category` is a short tag such as "player", "source", "sync", "app", "scan".
    public static func log(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)"
        queue.async {
            recentLines.append(line)
            if recentLines.count > recentLimit { recentLines.removeFirst(recentLines.count - recentLimit) }
            let url = fileURL
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
                try? FileManager.default.removeItem(at: rotatedURL)
                try? FileManager.default.moveItem(at: url, to: rotatedURL)
            }
            let data = (line + "\n").data(using: .utf8)!
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Newest first. Reads the file so lines from before this launch are included.
    public static func recent(limit: Int = 500) -> [String] {
        queue.sync {
            let onDisk = (try? String(contentsOf: fileURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            return Array(onDisk.suffix(limit).reversed())
        }
    }

    public static func clear() {
        queue.sync {
            recentLines.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
    }

    /// A URL with any user name and password removed, for logging.
    public static func safe(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.lastPathComponent }
        c.user = nil; c.password = nil
        if url.isFileURL { return "file:…/" + url.lastPathComponent }
        return c.url?.absoluteString.removingPercentEncoding ?? url.lastPathComponent
    }

    /// Device and app facts worth having at the top of a shared log.
    public static func header(appVersion: String, device: String, system: String) -> String {
        "Reel \(appVersion) on \(device), \(system)"
    }

    // MARK: - The main thread

    /// Times a piece of main-thread work and logs it under "main" when it took `threshold` or more,
    /// so a frozen screen can be put down to a named job. Wrap the known heavy jobs (a screen's
    /// rows, a sync batch, a probe) rather than guessing afterwards.
    @discardableResult
    public static func timeMain<T>(_ name: @autoclosure () -> String, threshold: TimeInterval = 0.5, _ work: () throws -> T) rethrows -> T {
        let began = Date()
        defer {
            let took = Date().timeIntervalSince(began)
            if took >= threshold { log("main", "\(name()) took \(String(format: "%.2f", took))s on the main thread") }
        }
        return try work()
    }

    nonisolated(unsafe) private static var watchingMainThread = false
    nonisolated(unsafe) private static var lastPong = Date()
    private static let pongLock = NSLock()

    /// A thread of its own pings the main thread four times a second and logs every stretch of a
    /// second or more during which the main thread answered nothing: "main thread busy for Ns
    /// (until HH:MM:SS)". The "took … on the main thread" lines from `timeMain` in the same
    /// window name the job; a stretch with none is work that is not yet wrapped. A late ping
    /// thread itself (the process starved or suspended) is reported as such, not as a busy main
    /// thread.
    public static func startMainThreadWatch() {
        guard !watchingMainThread else { return }
        watchingMainThread = true
        pongLock.withLock { lastPong = Date() }
        let thread = Thread {
            var blockedSince: Date?
            var lastTick = Date()
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = Date()
                let tickLate = now.timeIntervalSince(lastTick) - 0.25
                lastTick = now
                DispatchQueue.main.async { pongLock.withLock { lastPong = Date() } }
                let pong = pongLock.withLock { lastPong }
                let silent = now.timeIntervalSince(pong)
                if silent >= 1, blockedSince == nil { blockedSince = pong }
                if let since = blockedSince, pong > since {
                    // Recovered. The pong arrived at `pong`; the main thread was busy from `since`.
                    let busy = pong.timeIntervalSince(since)
                    blockedSince = nil
                    if tickLate > 1 {
                        log("main", "process starved or suspended for about \(String(format: "%.1f", busy))s (the watch thread itself was \(String(format: "%.1f", tickLate))s late)")
                    } else if busy >= 1 {
                        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
                        log("main", "main thread busy for \(String(format: "%.1f", busy))s (from \(f.string(from: since)) until \(f.string(from: pong)) UTC)")
                    }
                }
            }
        }
        thread.name = "reel.mainThreadWatch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
