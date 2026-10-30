import SwiftUI
import AVFoundation
import Combine
import SwiftData
import MediaCore
import Library
import Playback
import Metadata
import MediaSources

/// Owns the single playback engine, decides what plays next, and saves progress.
/// Presented as a full-screen cover from `RootView`.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var current: MediaItem?
    @Published private(set) var currentFile: MediaFile?
    @Published var loadError: String?
    @Published private(set) var upNext: MediaItem?
    @Published private(set) var previous: MediaItem?
    @Published var isLoading = false
    /// Set instead of `isPresented` when the file should play through AVPlayer (AirPlay, native container).
    /// `timeOffset` is added to the player's clock when saving progress: an AirPlay stream of an MKV
    /// that was started part-way has its own clock from zero.
    struct NativePlayback: Identifiable {
        var itemKey: String; var url: URL; var startAt: TimeInterval; var timeOffset: TimeInterval = 0; var knownDuration: TimeInterval = 0
        var title = ""; var subtitle = ""
        /// Chapter starts in the file's own time (the view subtracts `timeOffset` when seeking).
        var chapters: [Chapter] = []
        /// Audio delay, subtitle delay and dialogue boost the stream was made with.
        var adjustments = HLSRemuxer.Adjustments()
        var id: String { itemKey }
    }
    /// Pauses Apple's player when the sleep timer fires (the VLC engine is paused directly).
    @Published private(set) var sleepFired = 0
    /// The audio track VLC is playing, as an index among the audio tracks, when it has chosen one.
    private var currentAudioIndex: Int? {
        guard let id = engine.currentAudioTrack else { return nil }
        return engine.audioTracks.firstIndex { $0.id == id }
    }
    /// The last stream URL resolved for the current title (the engine forgets it once stopped).
    private(set) var lastPlaybackURL: URL?
    /// The playing file's video codec, as VLC names it, once it is known.
    private(set) var currentVideoCodec: String?
    /// MPEG-4 Part 2 (XviD/DivX) is what the iPad's hardware decoder gets wrong: green blocks or
    /// black. The player's own output is checked elsewhere; previews and thumbnails avoid it outright.
    static func needsSoftwareDecoding(_ codec: String?) -> Bool {
        guard let c = codec?.lowercased() else { return false }
        return ["mpeg-4 video", "mpeg-4 part 2", "xvid", "divx", "mp4v", "msmpeg"].contains { c.contains($0) }
    }
    /// Whether the scrubber's live preview may use the hardware decoder for the current file.
    var previewHardwareDecoding: Bool { AppSettings.current.hardwareDecoding && !Self.needsSoftwareDecoding(currentVideoCodec) }
    /// The stream the scrubber's live preview opens, or nil for a codec whose preview the iPad
    /// cannot show (MPEG-4 Part 2 comes out black or green); the thumbnails serve then.
    func previewURL(_ url: URL?) -> URL? { Self.needsSoftwareDecoding(currentVideoCodec) ? nil : url }

    private static func titles(for item: MediaItem) -> (String, String) {
        if item.kind == .episode { return (item.show?.title ?? item.title, [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ")) }
        return (item.title, item.year.map(String.init) ?? "")
    }
    /// Chapters for Apple's player: what VLC has loaded now, else what an earlier play recorded.
    private func nativeChapters(for file: MediaFile?) -> [Chapter] {
        if !engine.chapters.isEmpty { return engine.chapters }
        guard let file, !file.chapterStarts.isEmpty else { return [] }
        let starts = file.chapterStarts
        return starts.indices.map { i in
            let end = i + 1 < starts.count ? starts[i + 1] : (file.duration ?? starts[i])
            return Chapter(id: i, title: i < file.chapterTitles.count ? file.chapterTitles[i] : "Chapter \(i + 1)", start: starts[i], duration: max(0, end - starts[i]))
        }
    }
    /// Subtitle files Apple's player can be offered: sidecars on the share and downloaded ones.
    private func nativeSubtitles(for item: MediaItem, file: MediaFile?) async -> [HLSRemuxer.SubtitleFile] {
        var out: [HLSRemuxer.SubtitleFile] = []
        if let file { for s in await library.sidecarSubtitles(for: file) { out.append(.init(name: Self.subtitleName(s.name), language: Self.subtitleLanguage(s.name), data: s.data)) } }
        for url in SubtitleStore.subtitles(for: item.itemKey) {
            if let data = try? Data(contentsOf: url) { out.append(.init(name: Self.subtitleName(url.lastPathComponent), language: Self.subtitleLanguage(url.lastPathComponent), data: data)) }
        }
        Diagnostics.log("airplay", "subtitles for AirPlay: \(out.count) (sidecars on file: \(file?.sidecars.count ?? 0))")
        return out
    }
    private static func subtitleLanguage(_ name: String) -> String {
        let parts = (name as NSString).deletingPathExtension.lowercased().split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).map(String.init)
        for p in parts.reversed() where p.count == 2 || p.count == 3 { if ["en", "eng", "de", "ger", "deu", "fr", "fre", "fra", "es", "spa", "it", "ita", "ja", "jpn", "nl", "dut", "sv", "swe", "pt", "por"].contains(p) { return String(p.prefix(2)) } }
        return "en"
    }
    private static func subtitleName(_ file: String) -> String {
        let base = (file as NSString).deletingPathExtension
        let tags = base.lowercased().split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).map(String.init)
        let lang = subtitleLanguage(file)
        let name = ["en": "English", "de": "German", "fr": "French", "es": "Spanish", "it": "Italian", "ja": "Japanese", "nl": "Dutch", "sv": "Swedish", "pt": "Portuguese"][lang] ?? lang
        return tags.contains("forced") ? "\(name) (forced)" : tags.contains("sdh") ? "\(name) (SDH)" : name
    }
    @Published var nativePlayback: NativePlayback?
    /// Fill (crop) remembered for this show, applied by the player view when it appears.
    @Published private(set) var preferredFill: Bool?
    /// Speed remembered for this show, applied once playback has begun (VLC resets it on load).
    private var pendingRate: Float?
    /// Intro window learned from the viewer's own skips, for shows whose chapters do not say.
    @Published private(set) var learnedIntro: IntroMemory.Window?
    /// Where the end credits start, once known: a named or short final chapter first, else the
    /// dark-frame scan's result (kept per title). The Up Next card appears and counts down from here.
    @Published private(set) var creditsStart: TimeInterval?
    /// How long after `creditsStart` the Up Next countdown may begin. A frame scan places the start
    /// early by up to a keyframe, so its answer gets a grace period; a chapter or the viewer's own
    /// mark is exact and gets none.
    @Published private(set) var creditsGrace: TimeInterval = 0

    enum SleepTimer: Hashable { case minutes(Int), endOfEpisode }
    @Published private(set) var sleepTimer: SleepTimer?
    @Published private(set) var sleepFiresAt: Date?
    private var sleepTask: Task<Void, Never>?

    /// True while an AirPlay receiver is the audio route.
    static var airPlayActive: Bool { debugForceAirPlay || AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay } }
    /// Debug builds: pretend AirPlay is on, to exercise the remux and bridge without a receiver.
    static var debugForceAirPlay = false
    /// A container Apple's player can read (and so AirPlay can carry as video). MKV is not one.
    static func isNativeContainer(_ url: URL) -> Bool { ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) }
    /// True when AirPlay is the current audio route and the file can play through Apple's player:
    /// directly for a download or an HTTP URL, through the local bridge for SMB and WebDAV.
    static func prefersNativePlayer(for url: URL) -> Bool { airPlayActive && isNativeContainer(url) }

    /// The URL Apple's player should open for `file`: the URL itself when it can read it, else the
    /// local bridge serving the file from its share.
    private func nativeURL(for file: MediaFile?, playbackURL url: URL) async throws -> URL {
        let scheme = url.scheme?.lowercased() ?? ""
        if url.isFileURL || scheme == "http" || scheme == "https" { return url }
        guard let file else { throw SourceError.unsupported("AirPlay from \(scheme)") }
        let s = try await library.streamSource(for: file)
        guard s.source.supportsRangedReads else { await s.source.disconnect(); throw SourceError.unsupported("AirPlay from \(scheme)") }
        await bridgeTeardown?.value   // a stop from the last AirPlay play must land before this start
        return try await StreamBridge.shared.register(source: s.source, path: s.path, size: s.size)
    }

    /// Shows Apple's player in the player cover, in place of the VLC screen. One cover for both, so
    /// moving between them never drops back to the library in between.
    private func presentNative(_ playback: NativePlayback) async {
        isLoading = false
        loadingMessage = nil
        bridgeLive = true
        nativePlayback = playback
        isPresented = true
        if let url = lastPlaybackURL ?? engine.currentURL, playback.knownDuration > 0 {
            resolveCredits(key: playback.itemKey, url: url, duration: playback.knownDuration, chapters: playback.chapters)
        }
    }

    /// Starts an HLS copy of an MKV near `startAt` and serves it through the bridge. Returns the
    /// playlist URL and the time offset the stream's clock starts from, or nil when it failed or the
    /// user backed out (the notice says why). A copy from the start is kept for next time; one
    /// started part-way is not, so the offset is zero whenever a kept copy exists.
    private func prepareForAirPlay(file: MediaFile?, url: URL, item: MediaItem, startAt: TimeInterval, adjustments: HLSRemuxer.Adjustments? = nil) async -> (URL, TimeInterval)? {
        let adjustments = adjustments ?? HLSRemuxer.Adjustments(dialogueBoost: playbackOptions(for: item, settings: AppSettings.current).dialogueBoost)
        let key = file?.id.uuidString ?? url.absoluteString
        lastPlaybackURL = url
        isLoading = true
        loadingMessage = "Preparing for AirPlay…"
        do {
            let offset: TimeInterval = HLSRemuxer.completed(for: key) != nil && !adjustments.changesStream ? 0 : max(0, startAt - 5)
            let subtitles = await nativeSubtitles(for: item, file: file)
            // Every audio track travels; the one the player was on (else the preferred language) starts.
            let language = playbackOptions(for: item, settings: AppSettings.current).preferredAudioLanguage
            let dir = try await HLSRemuxer.shared.start(source: url, key: key, startAt: offset, subtitles: subtitles, preferredAudio: currentAudioIndex, preferredLanguage: language, adjustments: adjustments) { note in
                Task { @MainActor [weak self] in self?.loadingMessage = note }
            }
            loadingMessage = nil
            await bridgeTeardown?.value
            let base = try await StreamBridge.shared.register(directory: dir)
            return (base.appendingPathComponent(HLSRemuxer.playlistName(in: dir)), offset)
        } catch is CancellationError {
            loadingMessage = nil
            return nil
        } catch {
            loadingMessage = nil
            Diagnostics.log("airplay", "prepare failed: \(error.localizedDescription)")
            show(notice: error.localizedDescription)
            return nil
        }
    }

    /// A short message over the player (AirPlay with an MKV, for one). Clears itself.
    @Published var notice: String?
    private var noticeTask: Task<Void, Never>?
    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(7)); guard !Task.isCancelled else { return }; self?.notice = nil }
    }

    /// AirPlay chosen while VLC is playing: hand an MP4/MOV to Apple's player at the same position so
    /// the TV gets the picture; for anything else say why it is sound only.
    /// Where Apple's player is, in the file's own time; the native view keeps it current.
    var nativeTime: TimeInterval = 0

    private func routeChanged() {
        if !Self.airPlayActive, let playback = nativePlayback, let item = library.item(playback.itemKey) {
            // The receiver went away (AirPlay turned off, headphones): back to the device's own player
            // from the same position.
            Diagnostics.log("player", "AirPlay route gone; returning to the device at \(Int(nativeTime))s")
            if playback.knownDuration > 0 { library.recordProgress(itemKey: playback.itemKey, position: nativeTime, duration: playback.knownDuration) }
            releaseNative()
            play(item, settings: AppSettings.current)   // the cover stays up; VLC takes the screen back
            return
        }
        guard Self.airPlayActive, isPresented, nativePlayback == nil, let item = current, let url = engine.currentURL else { return }
        Diagnostics.log("player", "AirPlay route appeared mid-play; moving to the native player")
        switchToNativePlayer(item: item, url: url)
    }

    private func switchToNativePlayer(item: MediaItem, url: URL) {
        // With AirPlay already chosen, the route only switches once playback starts, so this runs
        // moments after a load: use the resume point, not a clock that has not caught up yet.
        let at = engine.effectiveTime
        saveProgress()
        let file = currentFile
        Task {
            do {
                let target: URL
                var startAt = at, offset: TimeInterval = 0
                if Self.isNativeContainer(url), let direct = try? await nativeURL(for: file, playbackURL: url) {
                    target = direct
                } else {
                    // An MKV: the sound keeps going on the TV for the few seconds the stream takes to start.
                    guard let (t, o) = await prepareForAirPlay(file: file, url: url, item: item, startAt: at) else { isLoading = false; return }
                    target = t; offset = o; startAt = o > 0 ? 0 : at
                }
                guard current?.itemKey == item.itemKey else { return }
                let chapters = nativeChapters(for: file)
                let (t, s) = Self.titles(for: item)
                // Stopping the engine zeroes its duration; without the real length a position
                // late in the file reads as "finished" and the title is marked watched.
                let known = engine.duration.nonZero ?? file?.duration ?? TimeInterval((item.runtimeMinutes ?? 0) * 60)
                engine.stop()
                ScrubPreview.shared.stop()
                await presentNative(NativePlayback(itemKey: item.itemKey, url: target, startAt: startAt, timeOffset: offset, knownDuration: known, title: t, subtitle: s, chapters: chapters))
            } catch {
                isLoading = false
                show(notice: "Couldn't move to AirPlay: \(error.localizedDescription)")
                Diagnostics.log("player", "native hand-over failed: \(error.localizedDescription)")
            }
        }
    }

    /// A seek beyond the part of the file copied so far: start the copy again from there. Apple's
    /// player gets a fresh stream whose clock starts at the new offset; the view rebuilds for the new URL.
    func restartNativeStream(at fileTime: TimeInterval, adjustments: HLSRemuxer.Adjustments? = nil) {
        guard let playback = nativePlayback, let item = current, let url = engine.currentURL ?? lastPlaybackURL else {
            Diagnostics.log("player", "native stream restart dropped: playback=\(nativePlayback != nil) current=\(current != nil) url=\(engine.currentURL != nil || lastPlaybackURL != nil)")
            return
        }
        let file = currentFile
        let adjustments = adjustments ?? playback.adjustments
        Task {
            HLSRemuxer.shared.cancel()
            await StreamBridge.shared.stop()
            guard let (target, offset) = await prepareForAirPlay(file: file, url: url, item: item, startAt: fileTime, adjustments: adjustments) else { isLoading = false; return }
            var next = playback
            next.url = target; next.timeOffset = offset; next.startAt = offset > 0 ? 0 : fileTime; next.adjustments = adjustments
            bridgeLive = true
            isLoading = false; loadingMessage = nil
            nativePlayback = next
        }
    }

    /// Apple's player closed: release the stream and leave the player.
    /// At the file's end the next episode follows, as it does in VLC's player, unless the sleep
    /// timer wanted this to be the last one.
    func endNativePlayback(atFileEnd: Bool = false, settings: AppSettings? = nil) {
        guard nativePlayback != nil || bridgeLive else { return }
        releaseNative()
        if atFileEnd, sleepTimer == .endOfEpisode { setSleepTimer(nil); Diagnostics.log("player", "sleep timer: stopping at the end of the episode"); dismiss(); return }
        if atFileEnd, let next = upNext, let settings, settings.autoPlayNext {
            Diagnostics.log("player", "AirPlay: on to the next episode, \(next.episodeCode ?? next.title)")
            play(next, settings: settings)
            return
        }
        dismiss()
    }
    /// Stops the copy and the bridge, and takes Apple's player off the screen (the cover stays).
    private func releaseNative() {
        nativePlayback = nil
        bridgeLive = false
        Self.debugForceAirPlay = false
        HLSRemuxer.shared.cancel()
        bridgeTeardown = Task { await StreamBridge.shared.stop() }
    }
    /// The bridge stop in flight, so the next AirPlay play waits for it rather than racing it.
    private var bridgeTeardown: Task<Void, Never>?
    private var bridgeLive = false
    /// What the spinner is waiting on, when it is something slow such as waking a sleeping NAS.
    @Published var loadingMessage: String?
    let engine = VLCPlaybackEngine()
    private let library: LibraryStore
    private var saveTimer: AnyCancellable?
    private var statusWatcher: AnyCancellable?
    private var nowPlaying = NowPlayingBridge()

    init(library: LibraryStore) {
        self.library = library
        statusWatcher = engine.$status.sink { [weak self] status in
            guard let self else { return }
            switch status {
            case .playing:
                if let rate = self.pendingRate { self.pendingRate = nil; self.engine.setRate(rate) }
            case .paused: self.saveProgress()
            case .ended: self.saveProgress(markWatched: true); self.handleEnded()
            default: break
            }
        }
        engine.onUserSeek = { [weak self] from, to in self?.noteUserSeek(from: from, to: to) }
        routeWatcher = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.routeChanged() }
    }
    private var routeWatcher: AnyCancellable?
    private var displayWatcher: AnyCancellable?
    /// The TV appeared or went away mid-play: reload at the same position with the matching
    /// frame-timing options (a two-second gap, once, rather than judder for the whole episode).
    func watchExternalDisplay(settings: AppSettings) {
        displayWatcher = ExternalDisplay.shared.$isConnected.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] connected in
            guard let self, self.isPresented, self.nativePlayback == nil, self.current != nil else { return }
            Diagnostics.log("player", connected ? "TV connected mid-play; reloading with frame drops allowed" : "TV gone mid-play; reloading for the device")
            self.reapplyOptions(settings: settings)
        }
    }

    /// A forward jump inside the first ten minutes, 20 s to 4 min long, is probably the viewer skipping
    /// the titles; remember it for the show and see whether two such jumps agree.
    private func noteUserSeek(from: TimeInterval, to: TimeInterval) {
        guard let current, current.kind == .episode, let show = current.show, from < 600, to - from >= 20, to - from <= 240 else { return }
        // A marked intro is the viewer's word; skips do not second-guess it.
        if ShowMarkers.show(show.itemKey)?.introLength != nil { return }
        // Skips the app made for the viewer (the button, a learned window) teach nothing new.
        if let intro = engine.chapters.intro, abs(to - (intro.start + intro.duration)) < 1 { return }
        if let learned = learnedIntro, abs(to - learned.end) < 1 { return }
        IntroMemory.record(showKey: show.itemKey, from: from, to: to)
        let window = IntroMemory.window(showKey: show.itemKey)
        if window != learnedIntro {
            learnedIntro = window
            if let window { Diagnostics.log("player", "learned intro for \(show.title.prefix(40)): \(Int(window.start))–\(Int(window.end))s") }
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTask?.cancel(); sleepTask = nil
        sleepTimer = timer
        sleepFiresAt = nil
        guard case .minutes(let m) = timer else { return }
        sleepFiresAt = Date().addingTimeInterval(TimeInterval(m * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(m * 60))
            guard !Task.isCancelled, let self else { return }
            Diagnostics.log("player", "sleep timer: pausing after \(m) min")
            self.engine.pause()
            self.sleepFired += 1
            self.saveProgress()
            self.sleepTimer = nil
            self.sleepFiresAt = nil
        }
    }
    /// True while a timer says the current episode is the last one tonight.
    var stopsAfterCurrent: Bool { sleepTimer == .endOfEpisode }

    /// A playback URL resolved ahead of time for the next episode (see `prepareNext`).
    private var prepared: (fileID: PersistentIdentifier, url: URL, subs: [URL], at: Date)?

    /// Resolves the next episode's URL now, while this one is still playing, so the hand-over does not
    /// wait on the SMB pre-flight connect (seconds on a NAS, a minute if it has to be woken). Called by
    /// the player a minute before the end; harmless to call more than once.
    func prepareNext() {
        guard let next = upNext, DownloadManager.localURL(for: next.itemKey) == nil, let file = library.preferredFile(next) else { return }
        if let prepared, prepared.fileID == file.persistentModelID, Date().timeIntervalSince(prepared.at) < 600 { return }
        Task {
            do {
                let (url, subs) = try await library.playbackURL(for: file)
                prepared = (file.persistentModelID, url, subs, Date())
                Diagnostics.log("player", "prepared next: \(Diagnostics.safe(url))")
            } catch {
                Diagnostics.log("player", "could not prepare next: \(error.localizedDescription)")
            }
        }
    }

    func play(_ item: MediaItem, file: MediaFile? = nil, fromStart: Bool = false, settings: AppSettings) {
        guard let file = file ?? library.preferredFile(item) else { loadError = "No file for \(item.title) yet. If the library is still syncing from iCloud, try again in a moment."; return }
        if nativePlayback != nil {
            // A Siri intent or a tap while Apple's player is up: one playback at a time.
            Diagnostics.log("player", "play requested while Apple's player was up; replacing it")
            releaseNative()
        }
        current = item
        currentFile = file
        upNext = item.kind == .episode ? library.episodeAfter(item) : nil
        previous = item.kind == .episode ? library.episodeBefore(item) : nil
        isPresented = true
        isLoading = true
        loadingMessage = nil
        loadError = nil
        Task {
            do {
                let url: URL, subs: [URL]
                if let local = DownloadManager.localURL(for: item.itemKey) {
                    (url, subs) = (local, [])
                    Diagnostics.log("player", "using downloaded copy for \(item.title.prefix(40))")
                } else if let prepared, prepared.fileID == file.persistentModelID, Date().timeIntervalSince(prepared.at) < 600 {
                    (url, subs) = (prepared.url, prepared.subs)
                    self.prepared = nil
                } else {
                    (url, subs) = try await library.playbackURL(for: file) { message in
                        Task { @MainActor in self.loadingMessage = message }
                    }
                }
                loadingMessage = nil
                let resume = fromStart ? 0 : (library.watchState(item.itemKey).map { $0.watched ? 0 : $0.position } ?? 0)
                // The audio route only reports AirPlay once the session is active; activating it here
                // means a title opened with AirPlay already chosen goes straight to Apple's player,
                // rather than starting VLC and handing over a moment later.
                NowPlayingBridge.activateSession()
                // An MP4 Apple's player can read straight from the share or server; otherwise (an MKV,
                // or a server only VLC can read from) VLC's HLS copy below carries it.
                if Self.prefersNativePlayer(for: url), await nativeSubtitles(for: item, file: file).isEmpty, let target = try? await nativeURL(for: file, playbackURL: url) {
                    let (t, s) = Self.titles(for: item)
                    await presentNative(NativePlayback(itemKey: item.itemKey, url: target, startAt: resume, title: t, subtitle: s, chapters: nativeChapters(for: file)))
                    return
                }
                if Self.airPlayActive, !ExternalDisplay.shared.isConnected {
                    // An MKV (or an MP4 with subtitle files): an HLS copy near the resume point, then Apple's player streams it.
                    if let (target, offset) = await prepareForAirPlay(file: file, url: url, item: item, startAt: resume) {
                        let known = file.duration ?? TimeInterval((item.runtimeMinutes ?? 0) * 60)
                        let (t, s) = Self.titles(for: item)
                        // A kept copy starts at zero and is seeked; a fresh one begins near the resume point itself.
                        await presentNative(NativePlayback(itemKey: item.itemKey, url: target, startAt: offset > 0 ? 0 : resume, timeOffset: offset, knownDuration: known, title: t, subtitle: s, chapters: nativeChapters(for: file)))
                        return
                    }
                    guard current?.itemKey == item.itemKey else { return }   // backed out while preparing
                    show(notice: "AirPlay is carrying the sound only. Turn on Screen Mirroring in Control Centre and Reel will put the full picture on the TV.")
                }
                let opts = playbackOptions(for: item, settings: settings)
                let subtitle = item.kind == .episode ? [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ") : item.year.map(String.init)
                let playbackItem = PlaybackItem(url: url, title: item.kind == .episode ? (item.show?.title ?? item.title) : item.title, subtitle: subtitle, startAt: resume,
                                                externalSubtitles: subs + SubtitleStore.subtitles(for: item.itemKey), itemKey: item.itemKey)
                let memory = TrackMemory.choice(for: Self.memoryKey(item))
                preferredFill = memory?.fill
                pendingRate = memory?.rate.flatMap { $0 == 1 ? nil : $0 }
                learnedIntro = item.kind == .episode ? item.show.flatMap { ShowMarkers.introWindow(showKey: $0.itemKey, itemKey: item.itemKey) ?? IntroMemory.window(showKey: $0.itemKey) } : nil
                creditsStart = nil; creditsGrace = 0
                engine.load(playbackItem, options: opts)
                scheduleScrubThumbnails(key: item.itemKey, url: url)
                if let show = item.show, resume < 600 { scheduleIntroSearch(showKey: show.itemKey, key: item.itemKey, url: url) }
                nowPlaying.attach(engine, title: playbackItem.title, subtitle: subtitle, artwork: nil)
                startSaveTimer()
                isLoading = false
            } catch {
                isLoading = false
                loadingMessage = nil
                loadError = error.localizedDescription
                Diagnostics.log("player", "could not resolve \(file.fileName): \(error.localizedDescription)")
            }
        }
    }

    /// Soon into a play, make the scrubber's preview frames this title lacks. Each frame
    /// is another open of the stream, so none are made on cellular, in Low Power Mode or on a hot device.
    private func scheduleScrubThumbnails(key: String, url: URL) {
        Task { [weak self] in
            // Soon after the start, not a minute in: a short visit should still leave frames behind.
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.current?.itemKey == key, [.playing, .paused, .buffering].contains(self.engine.status) else { return }
            guard DeviceConditions.allowsBackgroundWork, !(await DeviceConditions.isOnExpensivePath()) else {
                Diagnostics.log("player", "scrub thumbnails skipped (\(DeviceConditions.summary))"); return
            }
            ScrubThumbnails.shared.ensure(key: key, url: url, duration: self.engine.duration, softwareDecoding: Self.needsSoftwareDecoding(self.currentVideoCodec))
            self.resolveCredits(key: key, url: url)
        }
    }

    /// The marked intro, looked for in this episode as soon as it plays: its answer is wanted
    /// before the titles come round, a minute or more in.
    private func scheduleIntroSearch(showKey: String, key: String, url: URL) {
        guard ShowMarkers.needsIntroSearch(showKey: showKey, itemKey: key) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.current?.itemKey == key, DeviceConditions.allowsBackgroundWork else { return }
            ShowMarkers.locateIntro(showKey: showKey, itemKey: key, url: url, duration: self.engine.duration, softwareDecoding: Self.needsSoftwareDecoding(self.currentVideoCodec)) { [weak self] window in
                guard let self, self.current?.itemKey == key, let window else { return }
                self.learnedIntro = window
            }
        }
    }

    // MARK: - Marks

    private var markContext: (showKey: String, itemKey: String, url: URL)? {
        guard let current, current.kind == .episode, let show = current.show, let url = lastPlaybackURL ?? engine.currentURL else { return nil }
        return (show.itemKey, current.itemKey, url)
    }
    /// The show's marks, for the More sheet.
    var marks: ShowMarkers.Episode? { markContext.flatMap { ShowMarkers.episode(showKey: $0.showKey, itemKey: $0.itemKey) } }
    var showMarks: ShowMarkers.Show? { markContext.flatMap { ShowMarkers.show($0.showKey) } }

    func markIntroStart() {
        guard let c = markContext else { return }
        ShowMarkers.markIntroStart(showKey: c.showKey, itemKey: c.itemKey, url: c.url, time: engine.time, softwareDecoding: Self.needsSoftwareDecoding(currentVideoCodec))
        learnedIntro = ShowMarkers.introWindow(showKey: c.showKey, itemKey: c.itemKey)
    }
    func markIntroEnd() {
        guard let c = markContext else { return }
        ShowMarkers.markIntroEnd(showKey: c.showKey, itemKey: c.itemKey, time: engine.time)
        learnedIntro = ShowMarkers.introWindow(showKey: c.showKey, itemKey: c.itemKey)
    }
    func markCreditsStart() {
        guard let c = markContext else { return }
        ShowMarkers.markCreditsStart(showKey: c.showKey, itemKey: c.itemKey, url: c.url, time: engine.time, duration: engine.duration, softwareDecoding: Self.needsSoftwareDecoding(currentVideoCodec))
        creditsStart = engine.time; creditsGrace = 0
    }
    /// Forgets what the app worked out on its own for this show and episode (the scanned credits,
    /// the intro learned from skips, the intros it located) and starts over; marks stay.
    func forgetAutomatic() {
        guard let c = markContext else { return }
        CreditsMemory.forget(itemKey: c.itemKey)
        IntroMemory.forget(showKey: c.showKey)
        ShowMarkers.forgetLocated(showKey: c.showKey)
        Diagnostics.log("player", "forgot the automatic intro and credits for \(c.showKey.prefix(40))")
        learnedIntro = ShowMarkers.introWindow(showKey: c.showKey, itemKey: c.itemKey)
        creditsStart = nil; creditsGrace = 0
        resolveCredits(key: c.itemKey, url: c.url)
        scheduleIntroSearch(showKey: c.showKey, key: c.itemKey, url: c.url)
    }
    func clearMarks() {
        guard let c = markContext else { return }
        ShowMarkers.forget(showKey: c.showKey)
        learnedIntro = IntroMemory.window(showKey: c.showKey)
        creditsStart = nil; creditsGrace = 0
        resolveCredits(key: c.itemKey, url: c.url)
    }

    /// Chapters first; then the scan's stored result; else the scan, soon into the play (it is some
    /// fifty opens of the file, four seconds each over a share, so its answer is a few minutes away
    /// and is wanted before the end). Episodes only: a film's credits are not followed by anything,
    /// and its length makes the scan dear.
    private func resolveCredits(key: String, url: URL, duration: TimeInterval? = nil, chapters: [Chapter]? = nil) {
        let duration = duration ?? engine.duration, chapters = chapters ?? engine.chapters
        guard let current, current.kind == .episode, duration > 0, creditsStart == nil else { return }
        if let byChapter = chapters.creditsStart(fileDuration: duration) {
            creditsStart = byChapter; creditsGrace = 0
            Diagnostics.log("player", "credits by chapter at \(Int(byChapter))s")
            return
        }
        if let show = current.show, let marked = ShowMarkers.creditsStart(showKey: show.itemKey, itemKey: key, duration: duration) {
            let exact = ShowMarkers.episode(showKey: show.itemKey, itemKey: key)?.creditsStart != nil
            creditsStart = marked; creditsGrace = exact ? 0 : 5
            Diagnostics.log("player", "credits \(exact ? "marked" : "by the show's credits length") at \(Int(marked))s")
            if !exact {
                ShowMarkers.confirmCredits(showKey: show.itemKey, itemKey: key, url: url, estimate: marked, softwareDecoding: Self.needsSoftwareDecoding(currentVideoCodec)) { [weak self] found in
                    guard let self, self.current?.itemKey == key, let found else { return }
                    self.creditsStart = found; self.creditsGrace = 0
                }
            }
            return
        }
        creditsGrace = 15
        if let stored = CreditsMemory.start(for: key) {
            creditsStart = stored
            if let stored { Diagnostics.log("player", "credits known at \(Int(stored))s") }
            return
        }
        let software = Self.needsSoftwareDecoding(currentVideoCodec)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.current?.itemKey == key, DeviceConditions.allowsBackgroundWork else { return }
            CreditsMemory.scan(itemKey: key, url: url, duration: duration, softwareDecoding: software) { [weak self] start in
                guard let self, self.current?.itemKey == key else { return }
                self.creditsStart = start
            }
        }
    }

    /// The global playback settings, overridden by what the viewer chose last time for this show
    /// (or film): the audio language, and subtitles on in a language or off.
    private func playbackOptions(for item: MediaItem, settings: AppSettings) -> PlaybackOptions {
        var opts = PlaybackOptions()
        opts.hardwareDecoding = settings.hardwareDecoding
        opts.networkCachingMS = settings.networkCachingMS
        opts.preferredAudioLanguage = settings.audioLanguage
        opts.preferredSubtitleLanguage = settings.subtitleLanguage
        opts.subtitlesOnByDefault = settings.subtitlesOnByDefault
        opts.dialogueBoost = settings.dialogueBoost
        opts.allowFrameDrops = ExternalDisplay.shared.isConnected
        Self.applySubtitleStyle(&opts, settings)
        if let choice = TrackMemory.choice(for: Self.memoryKey(item)) {
            if let audio = choice.audioLanguage { opts.preferredAudioLanguage = audio }
            switch choice.subtitle {
            case "off": opts.subtitlesOnByDefault = false
            case "on": opts.subtitlesOnByDefault = true
            case let lang?: opts.subtitlesOnByDefault = true; opts.preferredSubtitleLanguage = lang
            case nil: break
            }
        }
        return opts
    }
    private static func memoryKey(_ item: MediaItem) -> String { item.show?.itemKey ?? item.itemKey }
    static func applySubtitleStyle(_ opts: inout PlaybackOptions, _ settings: AppSettings) {
        opts.subtitleScale = settings.subtitleScale
        opts.subtitleColor = UInt32(settings.subtitleColor, radix: 16) ?? 0xFFFFFF
        opts.subtitleBackground = settings.subtitleBackground
        opts.subtitleMargin = settings.subtitleRaised ? 90 : 0
    }

    func rememberRate(_ rate: Float) {
        guard let current else { return }
        TrackMemory.update(Self.memoryKey(current)) { $0.rate = rate == 1 ? nil : rate }
    }
    func rememberFill(_ fill: Bool) {
        guard let current else { return }
        TrackMemory.update(Self.memoryKey(current)) { $0.fill = fill }
    }

    /// Reloads the current title at the current position so a changed media option (dialogue boost)
    /// takes effect; VLC applies audio filters when the media opens.
    func reapplyOptions(settings: AppSettings) {
        guard let current else { return }
        saveProgress()
        let at = engine.time
        if let externalURL, currentFile == nil { playExternal(externalURL, title: current.title, settings: settings) }
        else { play(current, file: currentFile, settings: settings) }
        _ = at
    }

    /// For "Copy details" on the error card: the title and file, then the engine's own report.
    func failureReport() -> String {
        var lines = ["Reel playback report, \(Date().formatted(date: .abbreviated, time: .standard))"]
        if let current { lines.append("title: \(current.kind == .episode ? "\(current.show?.title ?? "") \(current.episodeCode ?? "")" : current.title)") }
        if let currentFile { lines.append("file: \(currentFile.fileName) (\(MediaFormat.bytes(currentFile.size)), \(currentFile.source?.type.rawValue ?? "?") source)") ; if let v = currentFile.videoCodec { lines.append("probe: \([currentFile.resolution, v, currentFile.audioSummary].compactMap { $0 }.joined(separator: " · "))") } }
        if let loadError { lines.append("load error: \(loadError)") }
        lines.append(engine.sessionReport())
        return lines.joined(separator: "\n")
    }

    func rememberAudioChoice(language: String?) {
        guard let current, let language else { return }
        TrackMemory.update(Self.memoryKey(current)) { $0.audioLanguage = language }
    }
    /// `language` is a code, "on" for a track with no language tag, or "off".
    func rememberSubtitleChoice(language: String) {
        guard let current else { return }
        TrackMemory.update(Self.memoryKey(current)) { $0.subtitle = language }
    }

    /// Plays something handed to us by another app: a file URL (Files, DS file, AirDrop) or a stream URL
    /// (`reel://play?url=`). Nothing is added to the library; watch state is keyed by the URL.
    func playExternal(_ url: URL, title: String? = nil, settings: AppSettings) {
        let name = title ?? url.lastPathComponent.removingPercentEncoding ?? url.absoluteString
        let key = ItemKey.unmatched(fileName: url.absoluteString, size: 0, duration: nil)
        let item = MediaItem(itemKey: key, kind: .film, title: name, confidence: .unmatched)
        current = item
        if nativePlayback != nil { releaseNative() }
        currentFile = nil
        externalURL = url
        upNext = nil
        isPresented = true
        isLoading = true
        loadError = nil
        // Security-scoped access for files other apps hand over; released when playback stops.
        if url.isFileURL, url.startAccessingSecurityScopedResource() { externalScopedURL = url }
        let resume = library.watchState(key).map { $0.watched ? 0 : $0.position } ?? 0
        var opts = PlaybackOptions()
        opts.hardwareDecoding = settings.hardwareDecoding
        opts.networkCachingMS = settings.networkCachingMS
        opts.preferredAudioLanguage = settings.audioLanguage
        opts.preferredSubtitleLanguage = settings.subtitleLanguage
        opts.subtitlesOnByDefault = settings.subtitlesOnByDefault
        opts.dialogueBoost = settings.dialogueBoost
        opts.allowFrameDrops = ExternalDisplay.shared.isConnected
        Self.applySubtitleStyle(&opts, settings)
        preferredFill = nil; pendingRate = nil; learnedIntro = nil; creditsStart = nil; creditsGrace = 0
        engine.load(PlaybackItem(url: url, title: name, subtitle: url.isFileURL ? nil : url.host, startAt: resume, itemKey: key), options: opts)
        scheduleScrubThumbnails(key: key, url: url)
        nowPlaying.attach(engine, title: name, subtitle: nil, artwork: nil)
        startSaveTimer()
        isLoading = false
    }
    private var externalScopedURL: URL?
    private var externalURL: URL?

    /// Plays the current item again from scratch: a fresh VLC input and, for network sources, a fresh
    /// connection. Used by the error card after a failed or timed-out open.
    func retry(settings: AppSettings) {
        loadError = nil
        if let externalURL, currentFile == nil { playExternal(externalURL, title: current?.title, settings: settings) }
        else if let current { play(current, file: currentFile, settings: settings) }
    }

    /// Plays a file that isn't in the library (file browser).
    func playFile(_ file: MediaFile, settings: AppSettings) {
        let temp = MediaItem(itemKey: ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: nil), kind: .film, title: file.fileName, confidence: .unmatched)
        play(temp, file: file, settings: settings)
    }

    /// Back within the first seconds means "the one before", like a music player; otherwise restart.
    func playPreviousOrRestart(settings: AppSettings) {
        if engine.time < 3, let previous { play(previous, settings: settings) } else { engine.seek(to: 0) }
    }

    func playNext(settings: AppSettings) {
        guard let next = upNext else { dismiss(); return }
        // Leaving during the credits counts as having watched it; leaving earlier keeps the place.
        if let playback = nativePlayback {
            let total = playback.knownDuration
            if total > 0 { library.recordProgress(itemKey: playback.itemKey, position: nativeTime >= total - 90 || (creditsStart.map { nativeTime >= $0 } ?? false) ? total : nativeTime, duration: total) }
        } else {
            let nearEnd = engine.status == .ended || (engine.duration > 0 && engine.time >= engine.duration - 60) || (creditsStart.map { engine.time >= $0 } ?? false)
            saveProgress(markWatched: nearEnd)
        }
        play(next, settings: settings)
    }

    func dismiss() {
        let wasNative = nativePlayback != nil || bridgeLive
        if nativePlayback != nil { releaseNative() }
        Diagnostics.log("player", "dismissed at \(Int(engine.time))s of \(Int(engine.duration))s")
        if !wasNative { saveProgress() }   // Apple's player saved its own position as it closed
        HLSRemuxer.shared.cancel()
        Self.debugForceAirPlay = false
        ScrubPreview.shared.stop()
        engine.stop()
        externalScopedURL?.stopAccessingSecurityScopedResource(); externalScopedURL = nil
        nowPlaying.detach()
        saveTimer = nil
        isPresented = false
        current = nil
        currentFile = nil
        currentVideoCodec = nil
        externalURL = nil
        learnedIntro = nil
        creditsStart = nil; creditsGrace = 0
        if case .minutes = sleepTimer { } else { setSleepTimer(nil) }
    }

    // MARK: -

    private func startSaveTimer() {
        // Every 30 s during playback (PLAN.md §10.4), not every tick, to keep iCloud traffic low.
        saveTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.saveProgress() }
        engine.onProbe = { [weak self] key, probe in
            guard let self, self.current?.itemKey == key else { return }
            self.currentVideoCodec = probe.videoCodec
            self.library.recordProbe(itemKey: key, fileID: self.currentFile?.id, videoCodec: probe.videoCodec, audio: probe.audio, subtitles: probe.subtitles, duration: probe.duration)
        }
    }

    /// Writes the current position now (the app is about to be suspended, or the user asked).
    /// The position now (the app is about to be suspended, or sync asked). During AirPlay the
    /// native view keeps `nativeTime` current, so that is what gets written.
    func flushProgress() {
        if let playback = nativePlayback, nativeTime > 0, playback.knownDuration > 0 {
            library.recordProgress(itemKey: playback.itemKey, position: nativeTime, duration: playback.knownDuration)
            return
        }
        saveProgress()
    }

    private func saveProgress(markWatched: Bool = false) {
        // While Apple's player is up it keeps the position itself; the engine's clock is stale.
        guard nativePlayback == nil else { return }
        if let f = currentFile, !engine.chapters.isEmpty { library.recordChapters(fileID: f.id, chapters: engine.chapters) }
        if let f = currentFile, !engine.audioTracks.isEmpty { library.recordAudioTracks(fileID: f.id, names: engine.audioTracks.map(\.name), languages: engine.audioTracks.map { $0.language ?? "" }) }
        guard let item = current, engine.duration > 0, !engine.resumePending || markWatched else { return }
        library.recordProgress(itemKey: item.itemKey, position: markWatched ? engine.duration : engine.time, duration: engine.duration)
    }

    private func handleEnded() {
        // The sleep timer's "end of episode": this was the last one tonight.
        if sleepTimer == .endOfEpisode { setSleepTimer(nil); Diagnostics.log("player", "sleep timer: stopping at the end of the episode"); dismiss(); return }
        // The player view shows the Up Next card; auto-advance is its job so the countdown is visible.
        if upNext == nil { dismiss() }
    }
}

private extension TimeInterval {
    var nonZero: TimeInterval? { self > 0 ? self : nil }
}
