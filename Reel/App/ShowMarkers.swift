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

    /// One open of the file for a batch of frames: a run comes off the decoder at speed, single
    /// frames by precise seeks. When the session cannot be made (no libvlc on this platform, a
    /// stream that will not open) each frame falls back to a thumbnail of its own.
    private final class Grab {
        private let grabber: FrameGrabber?
        private let url: URL, software: Bool
        init(url: URL, softwareDecoding: Bool) { self.url = url; software = softwareDecoding; grabber = FrameGrabber(url: url, softwareDecoding: softwareDecoding) }
        var isSession: Bool { grabber != nil }

        func run(from: TimeInterval, count: Int, spacing: TimeInterval) async -> [FrameFingerprint] {
            if let grabber {
                let got = await grabber.frames(from: from, count: count, spacing: spacing)
                if got.count >= count / 2 { return got.compactMap { FrameFingerprint($0.image) } }
            }
            var prints: [FrameFingerprint] = []
            for i in 0..<count {
                if let image = await ScrubThumbnails.frame(url: url, at: from + TimeInterval(i) * spacing, softwareDecoding: software, precise: true), let p = FrameFingerprint(image) { prints.append(p) }
            }
            return prints
        }

        func frame(at seconds: TimeInterval) async -> FrameFingerprint? {
            if let grabber, let image = await grabber.frame(at: seconds) { return FrameFingerprint(image) }
            guard let image = await ScrubThumbnails.frame(url: url, at: seconds, softwareDecoding: software, precise: true) else { return nil }
            return FrameFingerprint(image)
        }

        /// libvlc's teardown blocks, so it runs off the main thread.
        func close() async { guard let grabber else { return }; await Task.detached(priority: .utility) { grabber.close() }.value }
    }
    static let printsVersion = 2

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
            Diagnostics.log("player", "intro prints for \(showKey.prefix(40)): \(prints.count) kept, \(usable) usable, in \(Int(Date().timeIntervalSince(began)))s \(grab.isSession ? "from one open" : "a frame at a time")")
            update(showKey: showKey) { $0.introPrints = prints; $0.printSpacing = spacing; $0.printsVersion = Self.printsVersion }
            // Episodes searched with the old prints are searched again with these.
            update(showKey: showKey) { s in for k in s.episodes.keys where s.episodes[k]?.locatedIntro == nil { s.episodes[k]?.introSearched = false } }
        }
    }

    @MainActor
    static func markIntroEnd(showKey: String, itemKey: String, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        updateEpisode(showKey: showKey, itemKey: itemKey) { e in
            e.introEnd = time
            if let start = e.introStart, start >= time { e.introStart = nil }
        }
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
        let key = "reel.showMarkers.retrySearch.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        lock.withLock {
            var all = load()
            for k in all.keys { for e in all[k]!.episodes.keys where all[k]!.episodes[e]?.locatedIntro == nil { all[k]!.episodes[e]?.introSearched = false } }
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
            for dt in stride(from: -20.0, through: 20, by: 4) {
                guard DeviceConditions.allowsBackgroundWork else { await grab.close(); return }
                if let p = await grab.frame(at: max(0, estimate + dt)) { samples.append(.init(time: max(0, estimate + dt), print: p)) }
            }
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
        // A frame every step through the window (the step is just under the span the prints cover,
        // so one frame per step is enough), taken nearest the marked episodes' intro starts first:
        // each frame is an open of the file over the share, seconds apart, and the answer is wanted
        // before the titles arrive.
        let spacing = s.printSpacing ?? IntroLocator.provisionalSpacing
        let step = IntroLocator.coarseStep(forPrints: prints.count, spacing: spacing)
        let known = s.episodes.values.compactMap { $0.introStart ?? $0.locatedIntro }.sorted()
        var times = Array(stride(from: 0, through: limit, by: step))
        if !known.isEmpty { times.sort { a, b in let da = known.map { abs($0 - a) }.min()!, db = known.map { abs($0 - b) }.min()!; return da != db ? da < db : a < b } }
        searching.insert(itemKey)
        let began = Date()
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel intro search") { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        Diagnostics.log("player", "looking for the intro in \(itemKey.prefix(40)): \(times.count) frames up to \(Int(limit))s, every \(Int(step))s, nearest \(known.map { "\(Int($0))s" }.joined(separator: ", ")) first")
        Task {
            defer {
                searching.remove(itemKey)
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            }
            var estimate: TimeInterval?
            var looked = 0
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            for t in times {
                guard DeviceConditions.allowsBackgroundWork else { Diagnostics.log("player", "intro search paused (\(DeviceConditions.summary))"); await grab.close(); return }
                if let p = await grab.frame(at: t) {
                    looked += 1
                    if let start = IntroLocator.estimateStart(samples: [.init(time: t, print: p)], targets: prints, spacing: spacing) { estimate = start; break }
                }
            }
            guard var start = estimate else {
                await grab.close()
                updateEpisode(showKey: showKey, itemKey: itemKey) { $0.introSearched = true }
                Diagnostics.log("player", "intro not found in \(itemKey.prefix(40)) after \(looked) frames in \(Int(Date().timeIntervalSince(began)))s")
                found(nil)
                return
            }
            // Settle the start against the first fingerprint, either side of the estimate.
            if let first = prints.first, !first.isFlat {
                var best: (TimeInterval, Double)?
                for dt in [-1.0, 0, 1] {
                    let at = max(0, start + dt)
                    guard let p = await grab.frame(at: at) else { continue }
                    let d = p.distance(to: first)
                    if best == nil || d < best!.1 { best = (at, d) }
                }
                if let best, best.1 < IntroLocator.allowance(first, first) { start = best.0 }
            }
            await grab.close()
            updateEpisode(showKey: showKey, itemKey: itemKey) { $0.locatedIntro = start; $0.introSearched = true }
            Diagnostics.log("player", "intro found in \(itemKey.prefix(40)) at \(Int(start))s after \(looked) frames in \(Int(Date().timeIntervalSince(began)))s \(grab.isSession ? "from one open" : "a frame at a time")")
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
