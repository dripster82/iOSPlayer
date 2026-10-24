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
}
