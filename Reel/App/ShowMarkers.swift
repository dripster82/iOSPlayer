import Foundation
import CoreGraphics
import UIKit
import MediaCore
import Playback
import Sync

/// What the viewer marked by hand in the player's More sheet: where an episode's intro starts and
/// ends, and where its credits start. A mark is exact for the episode it was made in; for the rest
/// of the show it teaches lengths. The intro is the same footage every week but its start moves
/// with the cold open, so the marked start is fingerprinted and `locateIntro` looks for those
/// pictures in another episode's opening minutes. Credits run the same length every week, so their
/// start in another episode is the file's end less that length. Per device.
enum ShowMarkers {
    struct Episode: Codable, Equatable {
        var introStart: TimeInterval?
        var introEnd: TimeInterval?
        var creditsStart: TimeInterval?
        /// Where a scan placed the marked intro in this episode (nil once searched and not found).
        var locatedIntro: TimeInterval?
        var introSearched = false
    }
    struct Show: Codable, Equatable {
        /// Taken at the marked intro start and every `IntroLocator.spacing` seconds after it.
        var introPrints: [FrameFingerprint] = []
        /// Seconds between the prints (1 over a whole marked intro; 2 while only the start is marked).
        var printSpacing: TimeInterval?
        /// 2 once the prints come from precise seeks; older sets were keyframes and are retaken.
        var printsVersion: Int?
        var introLength: TimeInterval?
        var creditsLength: TimeInterval?
        /// Taken at the marked credits start: a show that opens its credits on the same card every
        /// week lets another episode's credits be placed exactly rather than by length alone.
        var creditsPrints: [FrameFingerprint] = []
        var episodes: [String: Episode] = [:]
        var updatedAt = Date.distantPast
        var pendingSync = false
        var isEmpty: Bool { introPrints.isEmpty && introLength == nil && creditsLength == nil && episodes.values.allSatisfy { $0.introStart == nil && $0.introEnd == nil && $0.creditsStart == nil } }
    }

    private static let key = "reel.showMarkers"
    private static let lock = NSLock()
    /// Called after a change that other devices should see; the app points it at the sync engine.
    nonisolated(unsafe) static var onChange: (() -> Void)?

    static func show(_ showKey: String) -> Show? { load()[showKey] }
    static func episode(showKey: String, itemKey: String) -> Episode? { load()[showKey]?.episodes[itemKey] }

    static func update(showKey: String, _ change: (inout Show) -> Void) {
        lock.lock()
        var all = load()
        var s = all[showKey] ?? Show()
        change(&s)
        s.updatedAt = Date(); s.pendingSync = true
        all[showKey] = s
        save(all)
        lock.unlock()
        onChange?()
    }
    static func updateEpisode(showKey: String, itemKey: String, _ change: (inout Episode) -> Void) {
        update(showKey: showKey) { s in var e = s.episodes[itemKey] ?? Episode(); change(&e); s.episodes[itemKey] = e }
    }
    /// Clears the show's marks. The record stays, emptied, so other devices clear theirs too.
    static func forget(showKey: String) { update(showKey: showKey) { $0 = Show() } }

    // MARK: Marks

    /// The intro starts at `time` in this episode: the time is kept, and fingerprints of the next
    /// seconds are taken so the intro can be found in other episodes. The frames come from the
    /// thumbnailer, a few seconds each over a share, so the prints land a little later.
    @MainActor
    static func markIntroStart(showKey: String, itemKey: String, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        updateEpisode(showKey: showKey, itemKey: itemKey) { e in
            e.introStart = time
            e.locatedIntro = nil; e.introSearched = false
            if let end = e.introEnd, end <= time { e.introEnd = nil }
        }
        update(showKey: showKey) { s in
            if let end = s.episodes[itemKey]?.introEnd { s.introLength = end - time }
            s.introPrints = []
        }
        Diagnostics.log("player", "intro marked at \(Int(time))s for \(showKey.prefix(40))")
        fingerprintIntro(showKey: showKey, itemKey: itemKey, url: url, time: time, softwareDecoding: softwareDecoding)
    }

    private static var fingerprinting: Set<String> = []
    /// True while a show's intro prints are being taken (the More sheet says so).
    static func isFingerprinting(showKey: String) -> Bool { fingerprinting.contains(showKey) }

    /// One open of the file for a batch of frames: a run comes off the decoder at speed, single
    /// frames by precise seeks. When the session cannot be made (no libvlc on this platform, a
    /// stream that will not open) each frame falls back to a thumbnail of its own.
    private final class Grab {
        private let grabber: FrameGrabber?
        private let url: URL, software: Bool
        init(url: URL, softwareDecoding: Bool) { self.url = url; software = softwareDecoding; grabber = FrameGrabber(url: url, softwareDecoding: softwareDecoding) }
        var isSession: Bool { grabber != nil }

        private(set) var usedSession = false

        func run(from: TimeInterval, count: Int, spacing: TimeInterval) async -> [FrameFingerprint] {
            if let grabber {
                let got = await grabber.frames(from: from, count: count, spacing: spacing).compactMap { FrameFingerprint($0.image) }
                let usable = got.filter { !$0.isFlat }.count
                if got.count >= count / 2, usable >= max(3, got.count / 4) { usedSession = true; return got }
                Diagnostics.log("player", "grab session gave \(got.count) frames, \(usable) usable (mean grey \(got.first.map { Int($0.brightness) } ?? -1)); taking them one at a time")
            }
            var prints: [FrameFingerprint] = []
            for i in 0..<count {
                if let image = await ScrubThumbnails.frame(url: url, at: from + TimeInterval(i) * spacing, softwareDecoding: software, precise: true), let p = FrameFingerprint(image) { prints.append(p) }
            }
            return prints
        }

        /// Where sampled frames are written as JPEGs for a look (Debug builds), or nil.
        var dumpFolder: URL?

        /// A clean frame at or just after `seconds`, with the time it is really from.
        func frame(at seconds: TimeInterval) async -> (time: TimeInterval, print: FrameFingerprint)? {
            if let grabber, let got = await grabber.frame(at: seconds), let p = FrameFingerprint(got.image) { usedSession = true; dump(got.image, at: got.time, how: "grab"); return (got.time, p) }
            guard let image = await ScrubThumbnails.frame(url: url, at: seconds, softwareDecoding: software, precise: true), let p = FrameFingerprint(image) else { return nil }
            dump(image, at: seconds, how: "thumb")
            return (seconds, p)
        }

        private func dump(_ image: CGImage, at seconds: TimeInterval, how: String) {
            #if DEBUG
            guard let dumpFolder else { return }
            try? FileManager.default.createDirectory(at: dumpFolder, withIntermediateDirectories: true)
            if let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) { try? data.write(to: dumpFolder.appendingPathComponent("\(Int(seconds))s-\(how).jpg")) }
            #endif
        }

        /// A frame a second from `from`, each handed to `each` (return true to stop) as it comes off
        /// a fresh start of the input. Returns false when no session could give frames.
        func scan(from: TimeInterval, count: Int, each: @escaping @Sendable (TimeInterval, FrameFingerprint) -> Bool) async -> Bool {
            guard let grabber else { return false }
            let dumpFolder = self.dumpFolder
            let got = await grabber.frames(from: from, count: count, spacing: 1, rate: 12) { time, image in
                guard let p = FrameFingerprint(image) else { return false }
                if let dumpFolder, Int(time) % 10 == 0 { Self.dumpImage(image, at: time, how: "scan", to: dumpFolder) }
                return each(time, p)
            }
            usedSession = !got.isEmpty
            return !got.isEmpty
        }
        static func dumpImage(_ image: CGImage, at seconds: TimeInterval, how: String, to folder: URL) {
            #if DEBUG
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) { try? data.write(to: folder.appendingPathComponent("\(Int(seconds))s-\(how).jpg")) }
            #endif
        }

        /// libvlc's teardown blocks, so it runs off the main thread.
        func close() async { guard let grabber else { return }; await Task.detached(priority: .utility) { grabber.close() }.value }
    }
    static let printsVersion = 6   // 6: taken after a 20 s run-up, past the decoder's grey placeholder

    /// The marked episode whose intro still has no prints (the app was put away before they were
    /// taken), so they can be taken when it next plays.
    static func needsFingerprints(showKey: String, itemKey: String) -> TimeInterval? {
        guard let s = show(showKey), !fingerprinting.contains(showKey) else { return nil }
        let provisional = s.introLength != nil && (s.printSpacing ?? IntroLocator.provisionalSpacing) != IntroLocator.spacing
        guard s.introPrints.isEmpty || (s.printsVersion ?? 1) < Self.printsVersion || provisional else { return nil }
        return s.episodes[itemKey]?.introStart
    }

    /// Takes the fingerprints of the intro from `time`: a frame every two seconds, each an open of
    /// the file over the share, a couple of minutes in all. A background assertion keeps the app
    /// running if it is put away meanwhile; the prints are stored only when all are in.
    @MainActor
    static func fingerprintIntro(showKey: String, itemKey: String, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        guard !fingerprinting.contains(showKey) else { return }
        fingerprinting.insert(showKey)
        let began = Date()
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel intro fingerprints") { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        // The whole intro a second at a time once its length is known; the first 38 s at 2 s until then.
        let length = show(showKey)?.introLength
        let spacing = length == nil ? IntroLocator.provisionalSpacing : IntroLocator.spacing
        let count = length.map { min(IntroLocator.maxCount, max(3, Int($0 / spacing) + 1)) } ?? IntroLocator.count
        Diagnostics.log("player", "fingerprinting the intro of \(itemKey.prefix(40)) from \(Int(time))s: \(count) frames \(Int(spacing))s apart")
        Task {
            defer {
                fingerprinting.remove(showKey)
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            }
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            let prints = await grab.run(from: time, count: count, spacing: spacing)
            await grab.close()
            let usable = prints.filter { !$0.isFlat }.count
            guard prints.count >= count / 2, usable >= 3 else {
                Diagnostics.log("player", "intro prints for \(showKey.prefix(40)) not taken: \(prints.count) frames, \(usable) usable; tried again next play")
                return
            }
            Diagnostics.log("player", "intro prints for \(showKey.prefix(40)): \(prints.count) kept, \(usable) usable, in \(Int(Date().timeIntervalSince(began)))s \(grab.usedSession ? "from one open" : "a frame at a time")")
            update(showKey: showKey) { $0.introPrints = prints; $0.printSpacing = spacing; $0.printsVersion = Self.printsVersion }
            // Episodes searched with the old prints are searched again with these.
            update(showKey: showKey) { s in for k in s.episodes.keys where s.episodes[k]?.locatedIntro == nil { s.episodes[k]?.introSearched = false } }
        }
    }

    @MainActor
    static func markIntroEnd(showKey: String, itemKey: String, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        // An end at or before the start is a slip of the thumb, not a new intro: nothing changes.
        if let start = episode(showKey: showKey, itemKey: itemKey)?.introStart, start >= time - 5 {
            Diagnostics.log("player", "intro end at \(Int(time))s ignored: the start is at \(Int(start))s")
            return
        }
        updateEpisode(showKey: showKey, itemKey: itemKey) { e in e.introEnd = time }
        update(showKey: showKey) { s in
            if let start = s.episodes[itemKey]?.introStart {
                s.introLength = time - start
                // The provisional prints (2 s apart, the first 38 s) give way to a frame a second
                // over the whole intro, taken when the episode next plays or straight away below.
                if (s.printSpacing ?? IntroLocator.provisionalSpacing) != IntroLocator.spacing { s.introPrints = [] }
            }
        }
        Diagnostics.log("player", "intro end marked at \(Int(time))s for \(showKey.prefix(40))")
        if let start = episode(showKey: showKey, itemKey: itemKey)?.introStart, show(showKey)?.introPrints.isEmpty == true {
            fingerprintIntro(showKey: showKey, itemKey: itemKey, url: url, time: start, softwareDecoding: softwareDecoding)
        }
    }

    @MainActor
    static func markCreditsStart(showKey: String, itemKey: String, url: URL, time: TimeInterval, duration: TimeInterval, softwareDecoding: Bool) {
        updateEpisode(showKey: showKey, itemKey: itemKey) { $0.creditsStart = time }
        update(showKey: showKey) { s in if duration > time { s.creditsLength = duration - time }; s.creditsPrints = [] }
        Diagnostics.log("player", "credits marked at \(Int(time))s for \(showKey.prefix(40)) (\(Int(duration - time))s long)")
        Task {
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            let prints = await grab.run(from: time, count: IntroLocator.count, spacing: IntroLocator.provisionalSpacing)
            await grab.close()
            Diagnostics.log("player", "credits prints for \(showKey.prefix(40)): \(prints.filter { !$0.isFlat }.count) usable of \(prints.count)")
            update(showKey: showKey) { $0.creditsPrints = prints }
        }
    }

    /// Searches made by the first build looked at the first minute only; let them run again, once.
    static func retryEarlySearchesOnce() {
        let key = "reel.showMarkers.retrySearch.v9"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        lock.withLock {
            var all = load()
            for k in all.keys { for e in all[k]!.episodes.keys where all[k]!.episodes[e]?.introStart == nil { all[k]!.episodes[e]?.introSearched = false; all[k]!.episodes[e]?.locatedIntro = nil } }
            save(all)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Drops what the app worked out on its own for a show (the located intros), keeping the marks.
    static func forgetLocated(showKey: String) {
        update(showKey: showKey) { s in for k in s.episodes.keys { s.episodes[k]?.locatedIntro = nil; s.episodes[k]?.introSearched = false } }
    }

    /// Looks around the estimated credits start (the file's end less the show's credits length) for
    /// the pictures the credits were marked on. A match pins the start exactly; `found` gets it on
    /// the main actor, or nothing when the credits open differently this week.
    @MainActor
    static func confirmCredits(showKey: String, itemKey: String, url: URL, estimate: TimeInterval, softwareDecoding: Bool, found: @escaping @MainActor (TimeInterval?) -> Void) {
        guard let s = show(showKey), s.creditsPrints.contains(where: { !$0.isFlat }), s.episodes[itemKey]?.creditsStart == nil else { return }
        let prints = s.creditsPrints
        Task {
            // The intro search comes first; the credits are a long way off.
            var waited = 0
            while searching.contains(itemKey), waited < 120 { try? await Task.sleep(for: .seconds(5)); waited += 1 }
            var samples: [IntroLocator.Sample] = []
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            guard DeviceConditions.allowsBackgroundWork else { await grab.close(); return }
            _ = await grab.scan(from: max(0, estimate - 20), count: 41) { time, p in samples.append(.init(time: time, print: p)); return false }
            await grab.close()
            let exact = IntroLocator.estimateStart(samples: samples, targets: prints, spacing: IntroLocator.provisionalSpacing)
            Diagnostics.log("player", "credits prints in \(itemKey.prefix(40)): \(exact.map { "matched at \(Int($0))s" } ?? "no match"), estimate \(Int(estimate))s")
            found(exact)
        }
    }

    // MARK: Answers

    /// The intro window for an episode: its own marks, or the marked intro located in it plus the
    /// learned length. Nil until a search has placed it.
    static func introWindow(showKey: String, itemKey: String) -> IntroMemory.Window? {
        guard let s = show(showKey) else { return nil }
        let e = s.episodes[itemKey]
        if let start = e?.introStart, let end = e?.introEnd, end > start { return .init(start: start, end: end) }
        if let start = e?.locatedIntro ?? e?.introStart, let length = s.introLength, length >= 10 { return .init(start: start, end: start + length) }
        return nil
    }

    /// Where the credits start in an episode: its own mark, else the show's credits length from the
    /// end. Nil when nothing was marked.
    static func creditsStart(showKey: String, itemKey: String, duration: TimeInterval) -> TimeInterval? {
        guard let s = show(showKey) else { return nil }
        if let marked = s.episodes[itemKey]?.creditsStart { return marked }
        if let length = s.creditsLength, duration > length + 30 { return duration - length }
        return nil
    }

    /// Whether the marked intro can be looked for in this episode: prints exist and it has not
    /// been searched (or marked) already.
    static func needsIntroSearch(showKey: String, itemKey: String) -> Bool {
        guard let s = show(showKey), s.introPrints.contains(where: { !$0.isFlat }), (s.printsVersion ?? 1) >= Self.printsVersion, s.introLength != nil else { return false }
        let e = s.episodes[itemKey]
        return e?.introStart == nil && !(e?.introSearched ?? false)
    }

    private static var searching: Set<String> = []
    /// What the continuous pass has seen so far: the last three matching frames and the start they imply.
    private final class Found: @unchecked Sendable {
        var recent: [(TimeInterval, TimeInterval, Double)] = []
        var start: TimeInterval?
        var looked = 0
    }
    /// True while the marked intro is being looked for in this episode; the heavier scans wait.
    static func isSearchingIntro(itemKey: String) -> Bool { searching.contains(itemKey) }

    /// Looks for the marked intro in the opening minutes of an episode: a frame every 8 s from the
    /// start, each compared to the fingerprints, stopping at the first that matches; then a finer
    /// look either side of the estimate to settle the start. `found` gets the window on the main actor.
    @MainActor
    static func locateIntro(showKey: String, itemKey: String, url: URL, duration: TimeInterval, softwareDecoding: Bool, found: @escaping @MainActor (IntroMemory.Window?) -> Void) {
        guard needsIntroSearch(showKey: showKey, itemKey: itemKey), !searching.contains(itemKey), let s = show(showKey), let length = s.introLength else { return }
        let prints = s.introPrints
        // Intros start within the first few minutes, after a cold open of any length. The file's
        // duration is often still unknown this early, so it only ever shrinks the window.
        let limit = duration > 0 ? min(600, max(120, duration / 4)) : 600
        let spacing = s.printSpacing ?? IntroLocator.provisionalSpacing
        // One continuous pass, a frame a second against the prints: from a little before the nearest
        // marked start (an episode's cold open is usually about the same length), then from the top.
        let known = s.episodes.values.compactMap { $0.introStart ?? $0.locatedIntro }.sorted()
        let nearestKnown = known.min() ?? 0
        let firstFrom = max(0, nearestKnown - length - 20)
        searching.insert(itemKey)
        let began = Date()
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel intro search") { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        Diagnostics.log("player", "looking for the intro in \(itemKey.prefix(40)): a frame a second from \(Int(firstFrom))s to \(Int(limit))s, then from the top")
        Task {
            defer {
                searching.remove(itemKey)
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            }
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            #if DEBUG
            let dump = Diagnostics.fileURL.deletingLastPathComponent().appendingPathComponent("intro-search", isDirectory: true).appendingPathComponent(String(itemKey.suffix(8)), isDirectory: true)
            try? FileManager.default.removeItem(at: dump)
            grab.dumpFolder = dump
            #endif
            // A start is accepted when three frames in a row agree on it to within 1.5 s: one
            // matching picture can be a coincidence, three consistent ones are the titles.
            let seen = Found()
            let stretches: [(TimeInterval, TimeInterval)] = firstFrom > 0 ? [(firstFrom, limit), (0, firstFrom)] : [(0, limit)]
            var looked = 0
            for (from, to) in stretches where seen.start == nil {
                guard DeviceConditions.allowsBackgroundWork else { Diagnostics.log("player", "intro search paused (\(DeviceConditions.summary))"); await grab.close(); return }
                let count = Int(to - from) + 1
                guard count > 0 else { continue }
                let got = await grab.scan(from: from, count: count) { time, print in
                    seen.looked += 1
                    guard let (i, sim) = IntroLocator.matches(print, in: prints) else { seen.recent = []; return false }
                    let start = time - TimeInterval(i) * spacing
                    seen.recent.append((time, start, sim))
                    if seen.recent.count > 3 { seen.recent.removeFirst() }
                    let starts = seen.recent.map(\.1)
                    if starts.count == 3, (starts.max()! - starts.min()!) <= 1.5 {
                        seen.start = starts.sorted()[1]
                        Diagnostics.log("player", "intro frames at " + seen.recent.map { "\(Int($0.0))s (print \(Int(($0.0 - $0.1) / spacing)), \(String(format: "%.2f", $0.2)))" }.joined(separator: ", ") + " agree")
                        return true
                    }
                    return false
                }
                looked = seen.looked
                if !got { Diagnostics.log("player", "intro pass \(Int(from))–\(Int(to))s gave no frames") }
            }
            await grab.close()
            guard let start = seen.start else {
                updateEpisode(showKey: showKey, itemKey: itemKey) { $0.introSearched = true }
                Diagnostics.log("player", "intro not found in \(itemKey.prefix(40)) after \(looked) frames in \(Int(Date().timeIntervalSince(began)))s")
                found(nil)
                return
            }
            updateEpisode(showKey: showKey, itemKey: itemKey) { $0.locatedIntro = start; $0.introSearched = true }
            Diagnostics.log("player", "intro found in \(itemKey.prefix(40)) at \(String(format: "%.1f", start))s after \(looked) frames in \(Int(Date().timeIntervalSince(began)))s")
            found(.init(start: start, end: start + length))
        }
    }

    private static func load() -> [String: Show] {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: Show].self, from: $0) } ?? [:]
    }
    private static func save(_ all: [String: Show]) {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Carries the marks through CloudKit as one document per show. Whole-document, last writer wins:
/// a mark made on the iPad reaches the iPhone, and the newer of two edits to the same show stands.
final class ShowMarkersSync: SyncedDocuments, @unchecked Sendable {
    func pendingKeys() -> [String] { ShowMarkers.pendingShowKeys() }
    func document(for key: String) -> (data: Data, updatedAt: Date)? { ShowMarkers.document(for: key) }
    func apply(key: String, data: Data, updatedAt: Date) { ShowMarkers.applyDocument(key: key, data: data, updatedAt: updatedAt) }
    func markSynced(key: String) { ShowMarkers.markSynced(key) }
    func markAllPending() { ShowMarkers.markAllPending() }
    func remove(key: String) { ShowMarkers.applyDocument(key: key, data: nil, updatedAt: Date()) }
}

extension ShowMarkers {
    static func pendingShowKeys() -> [String] { lock.withLock { load().filter { $0.value.pendingSync }.map(\.key) } }
    static func document(for showKey: String) -> (data: Data, updatedAt: Date)? {
        lock.withLock { load()[showKey].flatMap { s in (try? JSONEncoder().encode(s)).map { ($0, s.updatedAt) } } }
    }
    static func applyDocument(key: String, data: Data?, updatedAt: Date) {
        lock.withLock {
            var all = load()
            if let local = all[key], local.updatedAt >= updatedAt { return }
            var remote = data.flatMap { try? JSONDecoder().decode(Show.self, from: $0) } ?? Show()
            remote.updatedAt = updatedAt; remote.pendingSync = false
            all[key] = remote
            save(all)
            Diagnostics.log("sync", "show marks for \(key.prefix(40)) arrived from another device")
        }
    }
    static func markSynced(_ showKey: String) { lock.withLock { var all = load(); all[showKey]?.pendingSync = false; save(all) } }
    static func markAllPending() { lock.withLock { var all = load(); for k in all.keys { all[k]?.pendingSync = true }; save(all) } }
}
