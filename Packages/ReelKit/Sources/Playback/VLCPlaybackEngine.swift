#if canImport(VLCKit)
import Foundation
import Combine
import MediaCore
import VLCKit
#if canImport(UIKit)
import UIKit
#endif

/// VLCKit 4 wrapper. Owns one `VLCMediaPlayer` and republishes its state for SwiftUI.
/// The video is rendered into whatever view is assigned to `drawable` (see `VLCVideoView`), which
/// also hands the engine VLCKit's Picture in Picture controller once the video output is up.
@MainActor
public final class VLCPlaybackEngine: NSObject, PlaybackEngine, VLCMediaPlayerDelegate {

    @Published public private(set) var status: PlaybackStatus = .idle
    private func setStatus(_ new: PlaybackStatus) { if new != status { status = new } }
    /// Position and length. Observe `clock` in views that must redraw every tick; read `time` /
    /// `duration` everywhere else.
    public let clock = PlaybackClock()
    public var time: TimeInterval { clock.time }
    public var duration: TimeInterval { clock.duration }
    @Published public private(set) var rate: Float = 1
    @Published public private(set) var audioTracks: [MediaTrack] = []
    @Published public private(set) var subtitleTracks: [MediaTrack] = []
    @Published public private(set) var currentAudioTrack: Int?
    @Published public private(set) var currentSubtitleTrack: Int?
    @Published public private(set) var chapters: [Chapter] = []
    @Published public private(set) var subtitleDelay: TimeInterval = 0
    @Published public private(set) var audioDelay: TimeInterval = 0

    /// True until playback has actually reached the requested resume point (within 5 s). While true,
    /// nothing should save progress: a save at 0:11 would overwrite the real position with the start.
    public var resumePending: Bool {
        guard let item, item.startAt > 0 else { return false }
        return !resumeConfirmed
    }
    private var resumeConfirmed = false
    private var resumeAttempts = 0
    private var lastResumeAttempt = Date.distantPast

    /// True once VLC's video output has offered a Picture in Picture controller for the current media.
    @Published public private(set) var canStartPictureInPicture = false
    /// True while the system PiP window is showing the video.
    @Published public private(set) var isPictureInPictureActive = false

    public let player = VLCMediaPlayer()
    /// The object VLCKit's PiP window drives for play/pause/seek. `VLCVideoView` returns it from
    /// `mediaController()`; it talks to `player` directly because PiP calls arrive off the main actor.
    public let pictureInPictureMediaController: VLCPictureInPictureMediaControlling

    private weak var pipController: (any VLCPictureInPictureWindowControlling)?
    /// When the PiP window last closed. VLC's PiP output can take the inline video output down with it
    /// (closing the window with its X tells the system the content "stopped"), which would otherwise read
    /// as the stream ending and leave a black player; see `recoverAfterPictureInPicture`.
    private var pipEndedAt: Date?
    private var pipEndedRecently: Bool { pipEndedAt.map { Date().timeIntervalSince($0) < 4 } ?? false }
    private var item: PlaybackItem?
    private var options = PlaybackOptions()
    private var tracksLoaded = false
    private var appliedStart = false
    /// Once the viewer picks a subtitle track (or Off) in the sheet, the default rule stops interfering.
    private var userChoseSubtitle = false
    private var stopRequested = false
    private var hasPlayed = false
    /// VLCKit 4 addresses tracks by string id; the UI keeps integer ids, so these are indexed by `MediaTrack.id`.
    private var vlcAudioTracks: [VLCMediaPlayer.Track] = []
    private var vlcSubtitleTracks: [VLCMediaPlayer.Track] = []

    public override init() {
        pictureInPictureMediaController = PiPMediaController(player: player)
        super.init()
        player.delegate = self
    }

    /// The UIView VLC paints into. Set by `VLCVideoView`.
    public var drawable: AnyObject? {
        get { player.drawable as AnyObject? }
        set { player.drawable = newValue }
    }

    // MARK: - PlaybackEngine

    public func load(_ item: PlaybackItem, options: PlaybackOptions) {
        stop()
        self.item = item
        self.options = options
        tracksLoaded = false
        appliedStart = false
        resumeConfirmed = false
        resumeAttempts = 0
        userChoseSubtitle = false
        stopRequested = false
        hasPlayed = false

        guard let media = VLCMedia(url: item.url) else { setStatus(.failed("VLC couldn't open this URL.")); return }
        media.addOption(":network-caching=\(options.networkCachingMS)")
        media.addOption(":file-caching=1000")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        if options.hardwareDecoding {
            media.addOption(":codec=avcodec")
            media.addOption(":avcodec-hw=videotoolbox")
        } else {
            media.addOption(":avcodec-hw=none")
        }
        if let lang = options.preferredAudioLanguage { media.addOption(":audio-language=\(lang)") }
        // Asking VLC for a subtitle language makes it switch that track on, so only do it when subtitles
        // should be on by default; the preference is still used to pick a track when the user turns them on.
        if options.subtitlesOnByDefault, let lang = options.preferredSubtitleLanguage { media.addOption(":sub-language=\(lang)") }
        player.media = media
        setStatus(.opening)
        player.play()
        for sub in item.externalSubtitles { addExternalSubtitle(sub) }
        startOpenWatchdog()
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public func togglePlayPause() { player.isPlaying ? player.pause() : player.play() }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.time = VLCTime(int: Int32(clamped * 1000))
        clock.time = clamped
        // VLC keeps reporting the old position for a few ticks after a seek; don't let those drag the
        // scrubber back before the jump lands.
        ignoreTicksUntil = Date().addingTimeInterval(0.6)
        startSeekWatchdog(target: clamped)
    }
    private var ignoreTicksUntil = Date.distantPast
    private var lastTickAt = Date.distantPast
    private var seekWatchdog: Task<Void, Never>?
    private var openWatchdog: Task<Void, Never>?

    /// libvlc never times out an open on its own: an SMB server that has gone away, or a Wi-Fi link that
    /// dropped while the app was in the background, leaves the player "opening" indefinitely with the
    /// spinner up and no way to retry. After 25 s without a frame, give up with a clear error instead.
    private func startOpenWatchdog() {
        openWatchdog?.cancel()
        openWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled, !self.hasPlayed else { return }
            guard self.status == .opening || self.status == .buffering else { return }
            let target = self.item?.url.host.map { "on \($0)" } ?? "the file"
            self.stopRequested = true
            self.player.stop()
            self.setStatus(.failed("No response opening \(target) after 25 seconds. Check the server is on and reachable, then retry."))
        }
    }

    /// Seeking over SMB with libvlc 4 sometimes never comes back: the player sits in "buffering" and no
    /// time tick follows. If nothing has ticked a few seconds after a seek, try the seek another way;
    /// if that fails too, reload the stream at the target, which always works.
    private func startSeekWatchdog(target: TimeInterval) {
        seekWatchdog?.cancel()
        let issuedAt = Date()
        seekWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.status != .paused, self.status != .idle, self.status != .ended else { return }
            if self.lastTickAt < issuedAt {
                if self.duration > 0 { self.player.position = target / self.duration } else { self.player.time = VLCTime(int: Int32(target * 1000)) }
                self.player.play()
            }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self.status != .paused, self.status != .idle, self.status != .ended else { return }
            if self.lastTickAt < issuedAt, var current = self.item {
                current.startAt = target
                self.load(current, options: self.options)
            }
        }
    }

    public func skip(by seconds: TimeInterval) { seek(to: time + seconds) }

    public func setRate(_ rate: Float) {
        player.rate = rate
        self.rate = rate
    }

    public func selectAudioTrack(_ id: Int?) {
        if let id, vlcAudioTracks.indices.contains(id) {
            vlcAudioTracks[id].isSelectedExclusively = true
        } else {
            player.deselectAllAudioTracks()
        }
        currentAudioTrack = id
    }

    public func selectSubtitleTrack(_ id: Int?) {
        userChoseSubtitle = true
        applySubtitleTrack(id)
    }

    private func applySubtitleTrack(_ id: Int?) {
        if let id, vlcSubtitleTracks.indices.contains(id) {
            vlcSubtitleTracks[id].isSelectedExclusively = true
        } else {
            player.deselectAllTextTracks()
        }
        currentSubtitleTrack = id
    }

    public func setSubtitleDelay(_ seconds: TimeInterval) {
        player.currentVideoSubTitleDelay = Int(seconds * 1_000_000)
        subtitleDelay = seconds
    }

    public func setAudioDelay(_ seconds: TimeInterval) {
        player.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
        audioDelay = seconds
    }

    public func addExternalSubtitle(_ url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: false)
    }

    public func stop() {
        seekWatchdog?.cancel()
        openWatchdog?.cancel()
        if player.state != .stopped {
            stopRequested = true
            player.stop()
        }
        setStatus(.idle)
        clock.time = 0
        clock.duration = 0
        rate = 1
        audioTracks = []
        subtitleTracks = []
        vlcAudioTracks = []
        vlcSubtitleTracks = []
        chapters = []
        currentAudioTrack = nil
        currentSubtitleTrack = nil
        pipController = nil
        canStartPictureInPicture = false
        isPictureInPictureActive = false
    }

    private var fillEnabled = false
    private var appliedFill: (fill: Bool, width: Int, height: Int)?

    /// Fit letterboxes inside the drawable (VLC's default). Fill crops the picture to the drawable's
    /// aspect ratio so it covers the screen. VLCKit 4 replaced the `videoCropGeometry` string with a
    /// crop *ratio*, which is all Fill ever needed (points vs pixels doesn't matter for a ratio).
    public func setFill(_ fill: Bool) {
        fillEnabled = fill
        applyFill()
    }

    /// Re-applies the current Fit/Fill choice. `VLCVideoView` calls it whenever the drawable is laid out.
    public func drawableDidLayout() { applyFill() }

    /// Only touches VLC when the answer changes: every layout pass calls this, and reconfiguring the
    /// video output each time made the whole player stutter.
    private func applyFill() {
        let view = player.drawable as? PlatformView
        let w = Int((view?.bounds.width ?? 0).rounded()), h = Int((view?.bounds.height ?? 0).rounded())
        let wanted = (fill: fillEnabled && w > 0 && h > 0, width: w, height: h)
        if let applied = appliedFill, applied.fill == wanted.fill, !wanted.fill || (applied.width == w && applied.height == h) { return }
        appliedFill = wanted
        player.scaleFactor = 0
        if wanted.fill { player.setCropRatioWithNumerator(UInt32(w), denominator: UInt32(h)) } else { player.setCropRatioWithNumerator(0, denominator: 0) }
    }

    // MARK: - Picture in Picture

    /// Called by the drawable's `pictureInPictureReady` block. VLC creates one controller per video
    /// output, so this fires on every `load` once the first frame is up and the reference dies with it.
    public func pictureInPictureDidBecomeAvailable(_ controller: any VLCPictureInPictureWindowControlling) {
        pipController = controller
        controller.stateChangeEventHandler = { [weak self] started in
            Task { @MainActor in
                guard let self else { return }
                self.isPictureInPictureActive = started
                if !started { self.pipEndedAt = Date(); self.recoverAfterPictureInPicture() }
            }
        }
        canStartPictureInPicture = true
    }

    public func startPictureInPicture() {
        guard let pipController, !isPictureInPictureActive else { return }
        pipController.invalidatePlaybackState()
        pipController.startPictureInPicture()
    }

    public func stopPictureInPicture() {
        guard isPictureInPictureActive else { return }
        pipController?.stopPictureInPicture()
    }

    /// If the inline video output did not survive the PiP window closing, reload the same item at the
    /// current position so the picture comes back without the user restarting the app.
    private func recoverAfterPictureInPicture() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard var current = item, !isPictureInPictureActive else { return }
            let broken = !player.hasVideoOut || player.state == .stopped || player.state == .stopping
            guard broken else { return }
            current.startAt = max(0, time)
            load(current, options: options)
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    nonisolated public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in self.handleStateChange(newState) }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleTimeChange() }
    }

    nonisolated public func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor in
            if length > 0 { self.clock.duration = TimeInterval(length) / 1000 }
            self.pipController?.invalidatePlaybackState()
        }
    }

    nonisolated public func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in self.loadTracks() }   // subtitle streams often arrive after the audio ones
    }

    nonisolated public func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
        Task { @MainActor in self.syncSelection() }
    }

    nonisolated public func mediaPlayerChapterChanged(_ aNotification: Notification) {
        Task { @MainActor in if self.chapters.isEmpty { self.loadChapters() } }
    }

    private func handleStateChange(_ state: VLCMediaPlayerState) {
        pipController?.invalidatePlaybackState()
        switch state {
        case .opening: setStatus(.opening)
        case .buffering: status = player.isPlaying ? .playing : .buffering
        case .playing:
            openWatchdog?.cancel()
            setStatus(.playing)
            hasPlayed = true
            if !tracksLoaded { loadTracks() }
            attemptResumeIfNeeded(now: time)
        case .paused: setStatus(.paused)
        case .stopping, .stopped:
            // VLC 4 has no "ended" state: a stream that runs out goes stopping → stopped on its own.
            // Only our own `stop()` sets `stopRequested`, so anything else after playback began is the
            // end. `hasPlayed` also filters the stop events of the *previous* media, which can land
            // after `load()` has already moved on (stop is asynchronous in libvlc 4).
            guard !stopRequested, hasPlayed else { break }
            // A stop right after the PiP window closed is VLC tearing down its PiP output, not the end
            // of the film: hold as paused and let the PiP recovery reload the picture.
            if isPictureInPictureActive || pipEndedRecently { setStatus(.paused); recoverAfterPictureInPicture(); break }
            setStatus(.ended)
            canStartPictureInPicture = false
        case .error: setStatus(.failed("VLC couldn't play this file."))
        @unknown default: break
        }
    }

    /// Resume by seeking once the stream is actually playing and seekable (libvlc 4 drops earlier seeks).
    /// Confirmed when a tick lands near the target; retried a few times with different mechanisms;
    /// after that we give up and accept that the viewer is watching from the start. Returns true when a
    /// seek was just issued, so the caller skips this tick.
    @discardableResult
    private func attemptResumeIfNeeded(now: TimeInterval) -> Bool {
        guard let item, item.startAt > 0, !resumeConfirmed else { return false }
        let start = item.startAt
        if now >= start - 5 { resumeConfirmed = true; return false }
        guard player.isSeekable, now > 0.3, Date().timeIntervalSince(lastResumeAttempt) > 1.2 else { return false }
        lastResumeAttempt = Date()
        resumeAttempts += 1
        switch resumeAttempts {
        case 1: player.time = VLCTime(int: Int32(start * 1000))
        case 2: if duration > 0 { player.position = start / duration } else { player.time = VLCTime(int: Int32(start * 1000)) }
        case 3: player.jump(withOffset: Int32((start - now) * 1000))
        default: resumeConfirmed = true; return false   // give up: progress saves resume, from wherever we are
        }
        clock.time = start
        ignoreTicksUntil = Date().addingTimeInterval(0.6)
        return true
    }

    private func handleTimeChange() {
        // VLC reports time many times a second; publishing each one redraws the scrubber for nothing.
        let now = TimeInterval(player.time.intValue) / 1000
        lastTickAt = Date()
        if status == .buffering { setStatus(.playing) }
        if attemptResumeIfNeeded(now: now) { return }
        if Date() < ignoreTicksUntil { return }
        if abs(now - clock.time) >= 0.2 { clock.time = now }
        if let length = player.media?.length.intValue, length > 0 {
            let seconds = TimeInterval(length) / 1000
            if seconds != clock.duration { clock.duration = seconds }
        }
        if !tracksLoaded, now > 0.5 { loadTracks() }
        if status == .buffering { setStatus(.playing) }
    }

    /// Track lists are only reliable once the ES have been added, so this runs lazily and re-runs
    /// until it finds something.
    private func loadTracks() {
        vlcAudioTracks = player.audioTracks
        vlcSubtitleTracks = player.textTracks

        // Every @Published assignment redraws the whole player and rebuilds its gesture recognisers, and
        // VLC fires track events many times while a stream opens, so only publish actual changes.
        let newAudio = vlcAudioTracks.enumerated().map { i, t in
            MediaTrack(id: i, name: t.trackName, language: t.language ?? Self.language(in: t.trackName), codec: t.codecName(), channels: t.audio.map { Int($0.channelsNumber) })
        }
        let newSubs = vlcSubtitleTracks.enumerated().map { i, t in
            MediaTrack(id: i, name: t.trackName, language: t.language ?? Self.language(in: t.trackName), isForced: t.trackName.localizedCaseInsensitiveContains("forced"))
        }
        if newAudio != audioTracks { audioTracks = newAudio }
        if newSubs != subtitleTracks { subtitleTracks = newSubs }
        syncSelection()
        loadChapters()

        // VLC switches a subtitle track on whenever a default-flagged stream appears, which can be after
        // the first tracks load. Until the viewer chooses, keep enforcing "off by default" (forced tracks excepted).
        if !userChoseSubtitle, !options.subtitlesOnByDefault, let current = currentSubtitleTrack,
           !subtitleTracks.contains(where: { $0.id == current && $0.isForced }) {
            applySubtitleTrack(nil)
        }
        tracksLoaded = !audioTracks.isEmpty
    }

    private func syncSelection() {
        let a = vlcAudioTracks.firstIndex(where: \.isSelected), t = vlcSubtitleTracks.firstIndex(where: \.isSelected)
        if a != currentAudioTrack { currentAudioTrack = a }
        if t != currentSubtitleTrack { currentSubtitleTrack = t }
    }

    private func loadChapters() {
        let descs = player.chapterDescriptions(ofTitle: player.currentTitleIndex)
        let newChapters = descs.enumerated().map { i, d in
            Chapter(id: i, title: d.name ?? "Chapter \(i + 1)", start: TimeInterval(d.timeOffset.intValue) / 1000, duration: TimeInterval(d.durationTime.intValue) / 1000)
        }
        if newChapters != chapters { chapters = newChapters }
    }

    /// "Track 1 - [English]" → "English"
    private static func language(in name: String) -> String? {
        guard let open = name.lastIndex(of: "["), let close = name.lastIndex(of: "]"), open < close else { return nil }
        return String(name[name.index(after: open)..<close])
    }
}

/// Playback controls for the system PiP window. VLCKit calls these from AVKit's queues, so this is
/// deliberately not on the main actor and talks to the (thread-safe) `VLCMediaPlayer` directly,
/// like VideoLAN's own PiP example. The engine's published state catches up via the delegate.
private final class PiPMediaController: NSObject, VLCPictureInPictureMediaControlling, @unchecked Sendable {
    private let player: VLCMediaPlayer
    init(player: VLCMediaPlayer) { self.player = player }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(by offset: Int64, completion: @escaping () -> Void) {
        if !player.jump(withOffset: Int32(clamping: offset), completion: completion) { completion() }
    }
    func mediaLength() -> Int64 { player.media?.length.value?.int64Value ?? 0 }
    func mediaTime() -> Int64 { player.time.value?.int64Value ?? 0 }
    func isMediaSeekable() -> Bool { player.isSeekable }
    func isMediaPlaying() -> Bool { player.isPlaying }
}

#if canImport(UIKit)
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif
#endif
