import Foundation

/// Where a show's title sequence ends, learned from the viewer skipping it by hand. Chapters are the
/// first choice for Skip intro; most rips have none, or unnamed ones that cannot be told apart. When
/// the viewer scrubs forward past the titles in two episodes and lands within twenty seconds of the
/// same spot, that spot becomes the show's intro end and the button appears from then on.
/// Per device; keyed by the show's item key.
enum IntroMemory {
    struct Sample: Codable, Equatable { var from: Double; var to: Double }
    struct Window: Equatable { var start: TimeInterval; var end: TimeInterval }
    private static let key = "reel.introMemory"
    private static let maxSamples = 8

    static func record(showKey: String, from: TimeInterval, to: TimeInterval) {
        var all = load()
        var samples = all[showKey] ?? []
        samples.append(Sample(from: from, to: to))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        all[showKey] = samples
        save(all)
    }

    static func forget(showKey: String) {
        var all = load(); all[showKey] = nil; save(all)
    }

    /// The learned window, or nil until two skips agree.
    static func window(showKey: String) -> Window? {
        guard let samples = load()[showKey], samples.count >= 2 else { return nil }
        return window(from: samples)
    }

    static func window(from samples: [Sample]) -> Window? {
        // The biggest cluster of landing points within 20 s of each other, newest first on ties.
        var best: [Sample] = []
        for s in samples {
            let cluster = samples.filter { abs($0.to - s.to) <= 20 }
            if cluster.count > best.count { best = cluster }
        }
        guard best.count >= 2 else { return nil }
        let ends = best.map(\.to).sorted()
        let end = ends[ends.count / 2]
        // The titles start no later than the earliest point anyone skipped from; a skip from the very
        // start of the episode (a recap being skipped too) is allowed.
        let start = best.map(\.from).min() ?? 0
        guard end - start >= 15 else { return nil }
        return Window(start: start, end: end)
    }

    private static func load() -> [String: [Sample]] {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: [Sample]].self, from: $0) } ?? [:]
    }
    private static func save(_ all: [String: [Sample]]) {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}
