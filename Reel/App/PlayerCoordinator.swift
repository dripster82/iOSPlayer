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
    struct NativePlayback: Identifiable { var itemKey: String; var url: URL; var startAt: TimeInterval; var id: String { itemKey } }
    @Published var nativePlayback: NativePlayback?
    /// Fill (crop) remembered for this show, applied by the player view when it appears.
    @Published private(set) var preferredFill: Bool?
    /// Speed remembered for this show, applied once playback has begun (VLC resets it on load).
    private var pendingRate: Float?
    /// Intro window learned from the viewer's own skips, for shows whose chapters do not say.
    @Published private(set) var learnedIntro: IntroMemory.Window?

    enum SleepTimer: Hashable { case minutes(Int), endOfEpisode }
    @Published private(set) var sleepTimer: SleepTimer?
    @Published private(set) var sleepFiresAt: Date?
    private var sleepTask: Task<Void, Never>?

    /// True while an AirPlay receiver is the audio route.
    static var airPlayActive: Bool { AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay } }
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
        return try await StreamBridge.shared.register(source: s.source, path: s.path, size: s.size)
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
    private func routeChanged() {
        guard Self.airPlayActive, isPresented, let item = current, let url = engine.currentURL else { return }
        if Self.isNativeContainer(url) {
            Diagnostics.log("player", "AirPlay route appeared mid-play; moving to the native player")
            switchToNativePlayer(item: item, url: url)
        } else {
            show(notice: "AirPlay is carrying the sound. This is an MKV, which Apple's player cannot stream; for the picture on the TV, use Screen Mirroring in Control Centre.")
        }
    }

    private func switchToNativePlayer(item: MediaItem, url: URL) {
        let at = engine.time
        saveProgress()
        let file = currentFile
        Task {
            do {
                let target = try await nativeURL(for: file, playbackURL: url)
                engine.stop()
                ScrubPreview.shared.stop()
                isPresented = false
                nativePlayback = NativePlayback(itemKey: item.itemKey, url: target, startAt: at)
            } catch {
                show(notice: "Couldn't move to AirPlay: \(error.localizedDescription)")
                Diagnostics.log("player", "native hand-over failed: \(error.localizedDescription)")
            }
        }
    }

    /// Apple's player closed: release the bridge and its share connection.
    func endNativePlayback() {
        nativePlayback = nil
        Task { await StreamBridge.shared.stop() }
    }
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

    /// A forward jump inside the first ten minutes, 20 s to 4 min long, is probably the viewer skipping
    /// the titles; remember it for the show and see whether two such jumps agree.
    private func noteUserSeek(from: TimeInterval, to: TimeInterval) {
        guard let current, current.kind == .episode, let show = current.show, from < 600, to - from >= 20, to - from <= 240 else { return }
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
        guard let file = file ?? library.preferredFile(item) else { loadError = "No file for \(item.title)."; return }
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
                if Self.prefersNativePlayer(for: url) {
                    let target = try await nativeURL(for: file, playbackURL: url)
                    isLoading = false
                    isPresented = false
                    nativePlayback = NativePlayback(itemKey: item.itemKey, url: target, startAt: resume)
                    return
                }
                if Self.airPlayActive, !Self.isNativeContainer(url) {
                    show(notice: "AirPlay is carrying the sound. This is an MKV, which Apple's player cannot stream; for the picture on the TV, use Screen Mirroring in Control Centre.")
                }
                let opts = playbackOptions(for: item, settings: settings)
                let subtitle = item.kind == .episode ? [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ") : item.year.map(String.init)
                let playbackItem = PlaybackItem(url: url, title: item.kind == .episode ? (item.show?.title ?? item.title) : item.title, subtitle: subtitle, startAt: resume,
                                                externalSubtitles: subs + SubtitleStore.subtitles(for: item.itemKey), itemKey: item.itemKey)
                let memory = TrackMemory.choice(for: Self.memoryKey(item))
                preferredFill = memory?.fill
                pendingRate = memory?.rate.flatMap { $0 == 1 ? nil : $0 }
                learnedIntro = item.kind == .episode ? item.show.flatMap { IntroMemory.window(showKey: $0.itemKey) } : nil
                engine.load(playbackItem, options: opts)
                scheduleScrubThumbnails(key: item.itemKey, url: url)
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

    /// A minute into a play, make the scrubber's preview frames if this title has none yet. Each frame
    /// is another open of the stream, so none are made on cellular, in Low Power Mode or on a hot device.
    private func scheduleScrubThumbnails(key: String, url: URL) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.current?.itemKey == key, self.engine.status == .playing else { return }
            guard DeviceConditions.allowsBackgroundWork, !(await DeviceConditions.isOnExpensivePath()) else {
                Diagnostics.log("player", "scrub thumbnails skipped (\(DeviceConditions.summary))"); return
            }
            ScrubThumbnails.shared.ensure(key: key, url: url, duration: self.engine.duration)
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
        Self.applySubtitleStyle(&opts, settings)
        preferredFill = nil; pendingRate = nil; learnedIntro = nil
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
        play(next, settings: settings)
    }

    func dismiss() {
        Diagnostics.log("player", "dismissed at \(Int(engine.time))s of \(Int(engine.duration))s")
        saveProgress()
        ScrubPreview.shared.stop()
        engine.stop()
        externalScopedURL?.stopAccessingSecurityScopedResource(); externalScopedURL = nil
        nowPlaying.detach()
        saveTimer = nil
        isPresented = false
        current = nil
        currentFile = nil
        externalURL = nil
        learnedIntro = nil
        if case .minutes = sleepTimer { } else { setSleepTimer(nil) }
    }

    // MARK: -

    private func startSaveTimer() {
        // Every 30 s during playback (PLAN.md §10.4), not every tick, to keep iCloud traffic low.
        saveTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.saveProgress() }
        engine.onProbe = { [weak self] key, probe in
            guard let self, self.current?.itemKey == key else { return }
            self.library.recordProbe(itemKey: key, fileID: self.currentFile?.id, videoCodec: probe.videoCodec, audio: probe.audio, subtitles: probe.subtitles, duration: probe.duration)
        }
    }

    /// Writes the current position now (the app is about to be suspended, or the user asked).
    func flushProgress() { saveProgress() }

    private func saveProgress(markWatched: Bool = false) {
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
