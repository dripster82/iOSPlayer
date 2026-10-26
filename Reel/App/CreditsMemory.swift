import Foundation
import MediaCore
import Playback

/// Where an episode's end credits start, found by looking at its last stretch: a scan samples a
/// frame every few seconds and `CreditsFrame` says which look like credits (light lines of text on
/// a dark picture); `CreditsScan` turns the run into a start time. Chapters, when a file has them,
/// are checked first by the coordinator and never reach here. Results are kept per title, a
/// "nothing found" included, so a file is scanned once. Per device.
enum CreditsMemory {
    private static let key = "reel.creditsMemory"
    /// The stored value for a scanned file without credits.
    private static let none: Double = -1

    /// The credits start for a title: a time, `.some(nil)` when the scan found none, or nil when
    /// the title has not been scanned.
    static func start(for itemKey: String) -> TimeInterval?? {
        guard let v = load()[itemKey] else { return nil }
        return v == none ? .some(nil) : .some(v)
    }

    static func record(itemKey: String, start: TimeInterval?) {
        var all = load(); all[itemKey] = start ?? none; save(all)
    }

    private static var inProgress: Set<String> = []

    /// Scans the last stretch of the file unless it was scanned before; the result goes to `found`
    /// on the main actor. Frames come from the scrub thumbnailer, one every few seconds of runtime,
    /// so a 43-minute episode costs about fifty opens of the file: the scan stops if the device
    /// heats up or goes to Low Power Mode, and runs again on a later play.
    @MainActor
    static func scan(itemKey: String, url: URL, duration: TimeInterval, softwareDecoding: Bool, found: @escaping @MainActor (TimeInterval?) -> Void) {
        guard duration > 300, !inProgress.contains(itemKey), start(for: itemKey) == nil else { return }
        inProgress.insert(itemKey)
        Task {
            defer { inProgress.remove(itemKey) }
            let from = duration - CreditsScan.window(for: duration)
            Diagnostics.log("player", "credits scan of \(itemKey.prefix(40)): \(Int((duration - from) / CreditsScan.step)) frames from \(Int(from))s")
            var samples: [CreditsScan.Sample] = []
            var t = from
            while t < duration - 2 {
                guard DeviceConditions.allowsBackgroundWork else { Diagnostics.log("player", "credits scan paused (\(DeviceConditions.summary))"); return }
                if let image = await ScrubThumbnails.frame(url: url, at: t, softwareDecoding: softwareDecoding) {
                    samples.append(.init(time: t, credits: CreditsFrame.looksLikeCredits(image)))
                }
                t += CreditsScan.step
            }
            guard samples.count >= 6 else { Diagnostics.log("player", "credits scan of \(itemKey.prefix(40)) got \(samples.count) frames; not recorded"); return }
            let result = CreditsScan.start(in: samples)
            record(itemKey: itemKey, start: result)
            Diagnostics.log("player", "credits scan of \(itemKey.prefix(40)): \(samples.count) frames from \(Int(from))s, \(samples.filter(\.credits).count) credits-like; start \(result.map { "\(Int($0))s" } ?? "not found")")
            found(result)
        }
    }

    private static func load() -> [String: Double] {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    }
    private static func save(_ all: [String: Double]) {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}
