import Foundation

/// Stable identity for sync. A film on a NAS mounted under two different names must still match.
/// See PLAN.md §10.4.
public enum ItemKey {
    public static func film(tmdbID: Int) -> String { "movie:\(tmdbID)" }
    public static func show(tmdbID: Int) -> String { "show:\(tmdbID)" }
    public static func episode(showTMDbID: Int, season: Int, episode: Int) -> String {
        "show:\(showTMDbID):S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }

    /// Titles TMDb does not know (home video, a fictional test set, an obscure release) once the
    /// viewer has said what they are: keyed by the parsed title so copies and episodes group.
    public static func localFilm(title: String, year: Int?) -> String {
        var h = FNV1a(); h.update(normalise(title)); if let year { h.update(String(year)) }
        return "local-movie:\(h.hexDigest)"
    }
    public static func localShow(title: String) -> String {
        var h = FNV1a(); h.update(normalise(title))
        return "local-show:\(h.hexDigest)"
    }
    public static func localEpisode(showTitle: String, season: Int, episode: Int) -> String {
        "\(localShow(title: showTitle)):S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }
    static func normalise(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// An audiobook: the source and the folder (or single file) that is the book. The parts are
    /// numbered under it like episodes, so the series machinery carries them.
    public static func book(sourceID: UUID, path: String) -> String {
        var h = FNV1a(); h.update(sourceID.uuidString.lowercased()); h.update(path.lowercased())
        return "book:\(h.hexDigest)"
    }
    public static func bookPart(bookKey: String, index: Int) -> String { "\(bookKey):P\(String(format: "%03d", index))" }

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
