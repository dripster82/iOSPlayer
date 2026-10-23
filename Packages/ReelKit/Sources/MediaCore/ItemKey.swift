import Foundation

/// Stable identity for sync. A film on a NAS mounted under two different names must still match.
/// See PLAN.md §10.4.
public enum ItemKey {
    public static func film(tmdbID: Int) -> String { "movie:\(tmdbID)" }
    public static func show(tmdbID: Int) -> String { "show:\(tmdbID)" }
    public static func episode(showTMDbID: Int, season: Int, episode: Int) -> String {
        "show:\(showTMDbID):S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }

    /// Fallback for unmatched files: filename, size and duration hashed together.
    /// Duration is optional because a scan knows size before it knows duration.
    public static func unmatched(fileName: String, size: Int64, duration: TimeInterval?) -> String {
        var hasher = FNV1a()
        hasher.update(fileName.lowercased())
        hasher.update(String(size))
        if let duration { hasher.update(String(Int(duration))) }
        return "file:\(hasher.hexDigest)"
    }
}

/// Small, stable, non-cryptographic hash. Swift's `Hasher` is seeded per process, so it cannot be used for keys that cross devices.
struct FNV1a {
    private var hash: UInt64 = 0xcbf29ce484222325
    mutating func update(_ s: String) {
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
    }
    var hexDigest: String { String(hash, radix: 16) }
}
