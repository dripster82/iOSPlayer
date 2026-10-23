import Foundation

public enum MediaFormat {
    /// 1:02:03 or 2:03.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "42 min left" style.
    public static func minutesLeft(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        return m <= 1 ? "1 min left" : "\(m) min left"
    }

    public static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: count)
    }

    /// "S02E05"
    public static func episodeCode(season: Int, episode: Int) -> String {
        String(format: "S%02dE%02d", season, episode)
    }
}
