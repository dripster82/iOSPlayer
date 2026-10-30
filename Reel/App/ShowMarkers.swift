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
        /// Where a scan placed a marked intro in this episode (nil once searched and not found),
        /// and which pattern it matched, by the key of the episode that pattern was marked in.
        var locatedIntro: TimeInterval?
        var locatedPattern: String?
        var introSearched = false
    }
    /// One title sequence, marked in one episode. Shows change their titles between seasons, so a
    /// show keeps a pattern per distinct sequence and every episode is searched against all of them.
    struct IntroPattern: Codable, Equatable {
        /// The episode it was marked in, and that episode's season when known.
        var itemKey: String
        var season: Int?
        /// The marked start in that episode, and the intro's length once its end is marked too.
        var start: TimeInterval
        var length: TimeInterval?
        /// Taken at the start and every `spacing` seconds after it (0.25 over a whole intro; 2
        /// while only the start is marked). `version` says how they were taken; older sets are retaken.
        var prints: [FrameFingerprint] = []
        var spacing: TimeInterval?
        var version: Int?

        var isProvisional: Bool { (spacing ?? IntroLocator.provisionalSpacing) != IntroLocator.spacing }
        /// Prints that can be searched for: a whole intro's worth, taken the current way.
        var isUsable: Bool { length != nil && !isProvisional && (version ?? 1) >= ShowMarkers.printsVersion && prints.contains { !$0.isFlat } }
        /// Whether the prints are missing or stale and should be taken again.
        var needsPrints: Bool { prints.isEmpty || (version ?? 1) < ShowMarkers.printsVersion || (length != nil && isProvisional) }
        var label: String { season.map { "S\($0)" } ?? "one episode" }
    }
    /// The credits as marked in one episode: how long they run from the file's end, and prints of
    /// the card they open on. Credits grow between seasons too (SG-1's run 41 s in S10, 71 s in
    /// S3), so a show keeps one per marked season and another episode uses its nearest season's.
    struct CreditsPattern: Codable, Equatable {
        var itemKey: String
        var season: Int?
        var length: TimeInterval
        /// Taken at the marked credits start: a show that opens its credits on the same card every
        /// week lets another episode's credits be placed exactly rather than by length alone.
        var prints: [FrameFingerprint] = []
        var label: String { season.map { "S\($0)" } ?? "one episode" }
    }
    struct Show: Codable, Equatable {
        var patterns: [IntroPattern] = []
        var credits: [CreditsPattern] = []
        var episodes: [String: Episode] = [:]
        var updatedAt = Date.distantPast
        var pendingSync = false
        var isEmpty: Bool { patterns.isEmpty && credits.isEmpty && episodes.values.allSatisfy { $0.introStart == nil && $0.introEnd == nil && $0.creditsStart == nil } }

        /// The credits pattern for an episode of `season`: its own season's, else the nearest
        /// season's, with one of unknown season last.
        func credits(nearest season: Int?) -> CreditsPattern? {
            guard let season else { return credits.first }
            return credits.min { a, b in
                (a.season == season ? 0 : 1, a.season.map { abs($0 - season) } ?? 1000) < (b.season == season ? 0 : 1, b.season.map { abs($0 - season) } ?? 1000)
            }
        }

        /// The pattern marked in an episode.
        func pattern(for itemKey: String) -> IntroPattern? { patterns.first { $0.itemKey == itemKey } }
        var usablePatterns: [IntroPattern] { patterns.filter(\.isUsable) }
        /// The patterns in the order worth trying for an episode of `season`: its own season's
        /// first, then the nearest seasons. Every frame is compared to all of them anyway.
        func patterns(nearest season: Int?) -> [IntroPattern] {
            guard let season else { return usablePatterns }
            return usablePatterns.sorted { abs(($0.season ?? -100) - season) < abs(($1.season ?? -100) - season) }
        }

        init() {}
        // Earlier builds kept one set of prints per show; it becomes a pattern of unknown season,
        // attached to the episode the start was marked in.
        private enum Keys: String, CodingKey { case patterns, credits, creditsLength, creditsPrints, episodes, updatedAt, pendingSync, introPrints, printSpacing, printsVersion, introLength }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            patterns = try c.decodeIfPresent([IntroPattern].self, forKey: .patterns) ?? []
            credits = try c.decodeIfPresent([CreditsPattern].self, forKey: .credits) ?? []
            episodes = try c.decodeIfPresent([String: Episode].self, forKey: .episodes) ?? [:]
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
            pendingSync = try c.decodeIfPresent(Bool.self, forKey: .pendingSync) ?? false
            if patterns.isEmpty, let marked = episodes.first(where: { $0.value.introStart != nil }), let start = marked.value.introStart {
                patterns = [IntroPattern(itemKey: marked.key, season: nil, start: start,
                                         length: try c.decodeIfPresent(TimeInterval.self, forKey: .introLength),
                                         prints: try c.decodeIfPresent([FrameFingerprint].self, forKey: .introPrints) ?? [],
                                         spacing: try c.decodeIfPresent(TimeInterval.self, forKey: .printSpacing),
                                         version: try c.decodeIfPresent(Int.self, forKey: .printsVersion))]
            }
            if credits.isEmpty, let length = try c.decodeIfPresent(TimeInterval.self, forKey: .creditsLength) {
                let marked = episodes.first { $0.value.creditsStart != nil }?.key ?? ""
                credits = [CreditsPattern(itemKey: marked, season: nil, length: length, prints: try c.decodeIfPresent([FrameFingerprint].self, forKey: .creditsPrints) ?? [])]
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(patterns, forKey: .patterns); try c.encode(credits, forKey: .credits)
            try c.encode(episodes, forKey: .episodes)
            try c.encode(updatedAt, forKey: .updatedAt); try c.encode(pendingSync, forKey: .pendingSync)
        }
    }

    private static let key = "reel.showMarkers"
    private static let lock = NSLock()
    /// Called after a change that other devices should see; the app points it at the sync engine.
    nonisolated(unsafe) static var onChange: (() -> Void)?

    static func show(_ showKey: String) -> Show? { load()[showKey] }
    static func episode(showKey: String, itemKey: String) -> Episode? { load()[showKey]?.episodes[itemKey] }
    /// Whether the show has a marked intro (with or without its prints yet).
    static func hasIntroPattern(showKey: String) -> Bool { !(show(showKey)?.patterns.isEmpty ?? true) }

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
    /// seconds are taken so the intro can be found in other episodes. The pattern replaces this
    /// episode's own earlier one, or the one a search matched here (the same titles, so the fresh
    /// marks stand for it); otherwise it is a new pattern, as a season with different titles needs.
    @MainActor
    static func markIntroStart(showKey: String, itemKey: String, season: Int?, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        update(showKey: showKey) { s in
            var e = s.episodes[itemKey] ?? Episode()
            let replaces = e.locatedPattern
            e.introStart = time
            e.locatedIntro = nil; e.locatedPattern = nil; e.introSearched = false
            if let end = e.introEnd, end <= time { e.introEnd = nil }
            s.episodes[itemKey] = e
            let pattern = IntroPattern(itemKey: itemKey, season: season, start: time, length: e.introEnd.map { $0 - time })
            if let i = s.patterns.firstIndex(where: { $0.itemKey == itemKey }) ?? replaces.flatMap({ r in s.patterns.firstIndex { $0.itemKey == r } }) {
                s.patterns[i] = pattern
            } else {
                s.patterns.append(pattern)
            }
            s.patterns.sort { ($0.season ?? 0, $0.itemKey) < ($1.season ?? 0, $1.itemKey) }
        }
        Diagnostics.log("player", "intro marked at \(Int(time))s for \(showKey.prefix(40)) (\(season.map { "S\($0)" } ?? "season unknown"), \(show(showKey)?.patterns.count ?? 0) patterns)")
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
        func scan(from: TimeInterval, count: Int, each: @escaping @Sendable (TimeInterval, FrameFingerprint, CGImage) -> Bool) async -> Bool {
            guard let grabber else { return false }
            let dumpFolder = self.dumpFolder
            let got = await grabber.frames(from: from, count: count, spacing: 1, rate: 12) { time, image in
                guard let p = FrameFingerprint(image) else { return false }
                if let dumpFolder, Int(time) % 10 == 0 { Self.dumpImage(image, at: time, how: "scan", to: dumpFolder) }
                return each(time, p, image)
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

    /// The marked start in this episode whose pattern still has no prints (the app was put away
    /// before they were taken, or they were taken an older way), so they can be taken when it plays.
    static func needsFingerprints(showKey: String, itemKey: String) -> TimeInterval? {
        guard let s = show(showKey), !fingerprinting.contains(showKey), let p = s.pattern(for: itemKey), p.needsPrints else { return nil }
        return p.start
    }

    /// Takes the fingerprints of this episode's pattern from `time`: four a second over the whole
    /// intro once its length is known, a frame every two seconds over the first 38 s until then. A
    /// background assertion keeps the app running if it is put away meanwhile; the prints are
    /// stored only when all are in.
    @MainActor
    static func fingerprintIntro(showKey: String, itemKey: String, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        guard !fingerprinting.contains(showKey) else { return }
        fingerprinting.insert(showKey)
        let began = Date()
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel intro fingerprints") { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        let length = show(showKey)?.pattern(for: itemKey)?.length
        let spacing = length == nil ? IntroLocator.provisionalSpacing : IntroLocator.spacing
        let count = length.map { min(IntroLocator.maxCount, max(3, Int($0 / spacing) + 1)) } ?? IntroLocator.count
        Diagnostics.log("player", "fingerprinting the intro of \(itemKey.prefix(40)) from \(Int(time))s: \(count) frames \(spacing)s apart")
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
                Diagnostics.log("player", "intro prints for \(itemKey.prefix(40)) not taken: \(prints.count) frames, \(usable) usable; tried again next play")
                return
            }
            Diagnostics.log("player", "intro prints for \(itemKey.prefix(40)): \(prints.count) kept, \(usable) usable, in \(Int(Date().timeIntervalSince(began)))s \(grab.usedSession ? "from one open" : "a frame at a time")")
            update(showKey: showKey) { s in
                guard let i = s.patterns.firstIndex(where: { $0.itemKey == itemKey }) else { return }
                s.patterns[i].prints = prints; s.patterns[i].spacing = spacing; s.patterns[i].version = Self.printsVersion
                // Episodes searched without these prints (or with an older set) are searched again.
                for k in s.episodes.keys where s.episodes[k]?.locatedIntro == nil { s.episodes[k]?.introSearched = false }
            }
        }
    }

    @MainActor
    static func markIntroEnd(showKey: String, itemKey: String, url: URL, time: TimeInterval, softwareDecoding: Bool) {
        // An end at or before the start is a slip of the thumb, not a new intro: nothing changes.
        if let start = episode(showKey: showKey, itemKey: itemKey)?.introStart, start >= time - 5 {
            Diagnostics.log("player", "intro end at \(Int(time))s ignored: the start is at \(Int(start))s")
            return
        }
        update(showKey: showKey) { s in
            var e = s.episodes[itemKey] ?? Episode()
            e.introEnd = time
            s.episodes[itemKey] = e
            if let i = s.patterns.firstIndex(where: { $0.itemKey == itemKey }) {
                s.patterns[i].length = time - s.patterns[i].start
                // The provisional prints (2 s apart, the first 38 s) give way to four a second over
                // the whole intro, taken straight away below or when the episode next plays.
                if s.patterns[i].isProvisional { s.patterns[i].prints = [] }
            }
        }
        Diagnostics.log("player", "intro end marked at \(Int(time))s for \(showKey.prefix(40))")
        if let p = show(showKey)?.pattern(for: itemKey), p.prints.isEmpty {
            fingerprintIntro(showKey: showKey, itemKey: itemKey, url: url, time: p.start, softwareDecoding: softwareDecoding)
        }
    }
    @MainActor
    /// The credits start at `time` in this episode. The length from the file's end becomes this
    /// season's credits pattern (replacing an earlier mark in the same season or episode), and
    /// prints of the opening card are taken so other episodes can pin the start exactly.
    static func markCreditsStart(showKey: String, itemKey: String, season: Int?, url: URL, time: TimeInterval, duration: TimeInterval, softwareDecoding: Bool) {
        updateEpisode(showKey: showKey, itemKey: itemKey) { $0.creditsStart = time }
        guard duration > time else { return }
        update(showKey: showKey) { s in
            let pattern = CreditsPattern(itemKey: itemKey, season: season, length: duration - time)
            if let i = s.credits.firstIndex(where: { $0.itemKey == itemKey || (season != nil && $0.season == season) }) { s.credits[i] = pattern } else { s.credits.append(pattern) }
            s.credits.sort { ($0.season ?? 0, $0.itemKey) < ($1.season ?? 0, $1.itemKey) }
        }
        Diagnostics.log("player", "credits marked at \(Int(time))s for \(showKey.prefix(40)) (\(Int(duration - time))s long, \(season.map { "S\($0)" } ?? "season unknown"), \(show(showKey)?.credits.count ?? 0) patterns)")
        Task {
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            let prints = await grab.run(from: time, count: IntroLocator.count, spacing: IntroLocator.provisionalSpacing)
            await grab.close()
            Diagnostics.log("player", "credits prints for \(itemKey.prefix(40)): \(prints.filter { !$0.isFlat }.count) usable of \(prints.count)")
            update(showKey: showKey) { s in if let i = s.credits.firstIndex(where: { $0.itemKey == itemKey }) { s.credits[i].prints = prints } }
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
        update(showKey: showKey) { s in for k in s.episodes.keys { s.episodes[k]?.locatedIntro = nil; s.episodes[k]?.locatedPattern = nil; s.episodes[k]?.introSearched = false } }
    }

    /// Looks around the estimated credits start (the file's end less the season's credits length)
    /// for the pictures the credits were marked on, and failing that for the look of credits: light
    /// lines of text on a dark picture, three seconds of it and then mostly so to the end of the
    /// window. Either pins the start; `found` gets it on the main actor, or nothing when neither
    /// shows. The window is wider when the length came from another season, since that is exactly
    /// when it is likely to be off.
    @MainActor
    static func confirmCredits(showKey: String, itemKey: String, season: Int?, url: URL, estimate: TimeInterval, softwareDecoding: Bool, found: @escaping @MainActor (TimeInterval?) -> Void) {
        guard let s = show(showKey), let pattern = s.credits(nearest: season), s.episodes[itemKey]?.creditsStart == nil else { return }
        let prints = pattern.prints.filter { !$0.isFlat }
        let sameSeason = pattern.season != nil && pattern.season == season
        let before: TimeInterval = sameSeason ? 20 : 60
        let after: TimeInterval = min(sameSeason ? 20 : 60, max(5, pattern.length - 5))   // not past the file's end
        Task {
            // The intro search comes first; the credits are a long way off.
            var waited = 0
            while searching.contains(itemKey), waited < 120 { try? await Task.sleep(for: .seconds(5)); waited += 1 }
            var samples: [IntroLocator.Sample] = []
            var looks: [CreditsScan.Sample] = []
            let grab = Grab(url: url, softwareDecoding: softwareDecoding)
            guard DeviceConditions.allowsBackgroundWork else { await grab.close(); return }
            _ = await grab.scan(from: max(0, estimate - before), count: Int(before + after) + 1) { time, p, image in
                samples.append(.init(time: time, print: p))
                looks.append(.init(time: time, credits: CreditsFrame.looksLikeCredits(image)))
                return false
            }
            await grab.close()
            let byPrints = prints.isEmpty ? nil : IntroLocator.estimateStart(samples: samples, targets: prints, spacing: IntroLocator.provisionalSpacing)
            let byLook = CreditsScan.start(in: looks)
            let exact = byPrints ?? byLook
            Diagnostics.log("player", "credits in \(itemKey.prefix(40)) (\(pattern.label) length, estimate \(Int(estimate))s, \(looks.count) frames): prints \(byPrints.map { "matched at \(Int($0))s" } ?? "no match"), credits-like frames \(looks.filter(\.credits).count) \(byLook.map { "from \(Int($0))s" } ?? "with no run")")
            found(exact)
        }
    }

    // MARK: Answers

    /// The intro window for an episode: its own marks, or the pattern located in it plus that
    /// pattern's length. Nil until a search has placed it.
    static func introWindow(showKey: String, itemKey: String) -> IntroMemory.Window? {
        guard let s = show(showKey), let e = s.episodes[itemKey] else { return nil }
        if let start = e.introStart, let end = e.introEnd, end > start { return .init(start: start, end: end) }
        if let start = e.introStart, let length = s.pattern(for: itemKey)?.length, length >= 10 { return .init(start: start, end: start + length) }
        if let start = e.locatedIntro, let length = (e.locatedPattern.flatMap { s.pattern(for: $0) } ?? s.usablePatterns.first)?.length, length >= 10 { return .init(start: start, end: start + length) }
        return nil
    }

    /// Where the credits start in an episode: its own mark, else the show's credits length from the
    /// end. Nil when nothing was marked.
    static func creditsStart(showKey: String, itemKey: String, season: Int?, duration: TimeInterval) -> TimeInterval? {
        guard let s = show(showKey) else { return nil }
        if let marked = s.episodes[itemKey]?.creditsStart { return marked }
        if let length = s.credits(nearest: season)?.length, duration > length + 30 { return duration - length }
        return nil
    }

    /// Whether a marked intro can be looked for in this episode: some pattern has prints and the
    /// episode has not been searched (or marked) already.
    static func needsIntroSearch(showKey: String, itemKey: String) -> Bool {
        guard let s = show(showKey), !s.usablePatterns.isEmpty else { return false }
        let e = s.episodes[itemKey]
        return e?.introStart == nil && !(e?.introSearched ?? false)
    }

    private static var searching: Set<String> = []
    /// What the continuous pass has seen so far: the last three matching frames and the start they imply.
    private final class Found: @unchecked Sendable {
        var recent: [(time: TimeInterval, start: TimeInterval, similarity: Double, pattern: Int, print: Int)] = []
        var start: TimeInterval?
        var pattern: Int?
        var looked = 0
    }
    /// True while the marked intro is being looked for in this episode; the heavier scans wait.
    static func isSearchingIntro(itemKey: String) -> Bool { searching.contains(itemKey) }

    /// Looks for the show's intro patterns in the opening minutes of an episode: one continuous
    /// pass, a frame a second, each compared to every pattern's prints. `found` gets the window on
    /// the main actor once three frames in a row agree on where one pattern starts.
    @MainActor
    static func locateIntro(showKey: String, itemKey: String, season: Int?, url: URL, duration: TimeInterval, softwareDecoding: Bool, found: @escaping @MainActor (IntroMemory.Window?) -> Void) {
        guard needsIntroSearch(showKey: showKey, itemKey: itemKey), !searching.contains(itemKey), let s = show(showKey) else { return }
        let patterns = s.patterns(nearest: season)
        guard !patterns.isEmpty else { return }
        // Intros start within the first few minutes, after a cold open of any length. The file's
        // duration is often still unknown this early, so it only ever shrinks the window.
        let limit = duration > 0 ? min(600, max(120, duration / 4)) : 600
        // From a little before the nearest known start (an episode's cold open is usually about the
        // same length, and most alike within a season), then from the top.
        let sameSeason = patterns.first?.season == season
        let known = s.episodes.compactMap { k, e -> TimeInterval? in
            guard let t = e.introStart ?? e.locatedIntro else { return nil }
            if sameSeason, season != nil, s.pattern(for: k)?.season != season, e.locatedPattern.flatMap({ s.pattern(for: $0)?.season }) != season { return nil }
            return t
        }
        let longest = patterns.compactMap(\.length).max() ?? 60
        let firstFrom = max(0, (known.min() ?? 0) - longest - 20)
        searching.insert(itemKey)
        let began = Date()
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel intro search") { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        Diagnostics.log("player", "looking for the intro in \(itemKey.prefix(40)): a frame a second from \(Int(firstFrom))s to \(Int(limit))s, then from the top, against \(patterns.count) pattern(s) (\(patterns.map(\.label).joined(separator: ", ")))")
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
            // A start is accepted when three frames in a row match the same pattern and agree on
            // its start to within 1.5 s: one matching picture can be a coincidence, three
            // consistent ones are the titles.
            let seen = Found()
            let stretches: [(TimeInterval, TimeInterval)] = firstFrom > 0 ? [(firstFrom, limit), (0, firstFrom)] : [(0, limit)]
            var looked = 0
            for (from, to) in stretches where seen.start == nil {
                guard DeviceConditions.allowsBackgroundWork else { Diagnostics.log("player", "intro search paused (\(DeviceConditions.summary))"); await grab.close(); return }
                let count = Int(to - from) + 1
                guard count > 0 else { continue }
                let got = await grab.scan(from: from, count: count) { time, print, _ in
                    seen.looked += 1
                    // The pattern this frame matches best, with the start it implies.
                    var best: (pattern: Int, start: TimeInterval, similarity: Double, print: Int)?
                    for (p, pattern) in patterns.enumerated() {
                        guard let (i, sim) = IntroLocator.matches(print, in: pattern.prints), sim > (best?.similarity ?? 0) else { continue }
                        best = (p, time - TimeInterval(i) * (pattern.spacing ?? IntroLocator.spacing), sim, i)
                    }
                    guard let best else { seen.recent = []; return false }
                    if seen.recent.last?.pattern != best.pattern { seen.recent = [] }
                    seen.recent.append((time, best.start, best.similarity, best.pattern, best.print))
                    if seen.recent.count > 3 { seen.recent.removeFirst() }
                    let starts = seen.recent.map(\.start)
                    if starts.count == 3, (starts.max()! - starts.min()!) <= 1.5 {
                        seen.start = starts.sorted()[1]; seen.pattern = best.pattern
                        Diagnostics.log("player", "intro frames at " + seen.recent.map { "\(Int($0.time))s (print \($0.print), \(String(format: "%.2f", $0.similarity)))" }.joined(separator: ", ") + " agree on pattern \(patterns[best.pattern].label)")
                        return true
                    }
                    return false
                }
                looked = seen.looked
                if !got { Diagnostics.log("player", "intro pass \(Int(from))–\(Int(to))s gave no frames") }
            }
            await grab.close()
            guard let start = seen.start, let p = seen.pattern, let length = patterns[p].length else {
                updateEpisode(showKey: showKey, itemKey: itemKey) { $0.introSearched = true }
                Diagnostics.log("player", "intro not found in \(itemKey.prefix(40)) after \(looked) frames in \(Int(Date().timeIntervalSince(began)))s")
                found(nil)
                return
            }
            updateEpisode(showKey: showKey, itemKey: itemKey) { $0.locatedIntro = start; $0.locatedPattern = patterns[p].itemKey; $0.introSearched = true }
            Diagnostics.log("player", "intro found in \(itemKey.prefix(40)) at \(String(format: "%.1f", start))s (pattern \(patterns[p].label)) after \(looked) frames in \(Int(Date().timeIntervalSince(began)))s")
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
