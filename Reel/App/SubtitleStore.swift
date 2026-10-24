import Foundation
import MediaCore

/// Downloaded subtitle files, kept per item so they come back on the next play of that episode or
/// film. Documents/Subtitles/<item>/<language>-<fileID>.srt. Small, so never evicted.
enum SubtitleStore {
    private static var root: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func folder(for itemKey: String) -> URL {
        let safe = itemKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemKey
        return root.appendingPathComponent(String(safe.prefix(200)), isDirectory: true)
    }

    static func subtitles(for itemKey: String) -> [URL] {
        let dir = folder(for: itemKey)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["srt", "ass", "ssa", "vtt", "sub"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    static func save(_ data: Data, itemKey: String, language: String, fileID: Int, originalName: String) throws -> URL {
        let dir = folder(for: itemKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = (originalName as NSString).pathExtension.lowercased()
        let url = dir.appendingPathComponent("\(language)-\(fileID).\(ext.isEmpty ? "srt" : ext)")
        try data.write(to: url, options: .atomic)
        Diagnostics.log("subtitles", "saved \(language) #\(fileID) for \(itemKey.prefix(60))")
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// Which audio and subtitle track the viewer chose for a show (or a film), so the next episode
/// starts the same way: Japanese audio with English subtitles for one anime, dubbed for another.
/// Per device; keyed by the show's item key.
enum TrackMemory {
    struct Choice: Codable, Equatable {
        /// Language of the chosen audio track, as VLC reported it ("jpn", "en"…).
        var audioLanguage: String?
        /// Language of the chosen subtitle track, "off" when the viewer turned subtitles off, nil when untouched.
        var subtitle: String?
    }
    private static let key = "reel.trackMemory"

    static func choice(for showKey: String) -> Choice? {
        guard let data = UserDefaults.standard.data(forKey: key), let all = try? JSONDecoder().decode([String: Choice].self, from: data) else { return nil }
        return all[showKey]
    }

    static func update(_ showKey: String, _ change: (inout Choice) -> Void) {
        var all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) } ?? [:]
        var c = all[showKey] ?? Choice()
        change(&c)
        all[showKey] = c
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}
