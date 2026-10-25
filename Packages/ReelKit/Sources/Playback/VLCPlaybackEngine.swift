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
    private func setStatus(_ new: PlaybackStatus) {
        guard new != status else { return }
        status = new
        log("status \(new) at \(Int(clock.time))s")
    }
    /// Position and length. Observe `clock` in views that must redraw every tick; read `time` /
    /// `duration` everywhere else.
    public let clock = PlaybackClock()
    /// What the stream turned out to contain, reported once the tracks are known: video codec name,
    /// an audio summary ("DTS 5.1 · AAC 2.0"), a subtitle summary, and the duration in seconds.
    public struct Probe: Sendable, Equatable { public var videoCodec: String?; public var audio: String?; public var subtitles: String?; public var duration: TimeInterval }
    public var onProbe: ((String, Probe) -> Void)?
    /// What is playing, for a second player that wants the same stream (the scrub preview).
    public var currentURL: URL? { item?.url }
    public var currentOptions: PlaybackOptions { options }
    /// Every seek the viewer asked for (scrubber, double-tap, skip buttons), as (from, to). Internal
    /// seeks (resume, reconnect) do not report. Used to learn where a show's titles end.
    public var onUserSeek: ((TimeInterval, TimeInterval) -> Void)?

    /// The last 40 things this engine logged, for the failure report.
    private var events: [String] = []
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private func log(_ message: String) {
        Diagnostics.log("player", message)
        events.append("\(Self.stamp.string(from: Date())) \(message)")
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }

    /// Everything known about this playback session, for "Copy details" on the error card: what was
    /// playing, where it got to, how often it reconnected, VLC's counters, the tracks, and the log.
    public func sessionReport() -> String {
        var lines = ["status: \(status)", "position: \(Int(clock.time))s of \(Int(clock.duration))s, rate \(rate)"]
        if let item { lines.append("url: \(Diagnostics.safe(item.url))"); lines.append("start at: \(Int(item.startAt))s, external subtitles: \(item.externalSubtitles.count)") }
        lines.append("reconnects: \(recoveries), open timeouts: \(openTimeouts), player rebuilt: \(rebuilds)")
        lines.append("options: hw=\(options.hardwareDecoding) cache=\(options.networkCachingMS)ms boost=\(options.dialogueBoost) audio=\(options.preferredAudioLanguage ?? "-") subs=\(options.subtitlesOnByDefault ? options.preferredSubtitleLanguage ?? "on" : "off")")
        if let s = player.media?.statistics {
            lines.append("video: decoded \(s.decodedVideo), shown \(s.displayedPictures), lost \(s.lostPictures)")
            lines.append("audio: decoded \(s.decodedAudio), played \(s.playedAudioBuffers), lost \(s.lostAudioBuffers)")
            lines.append("demux: read \(s.demuxReadBytes / 1_000_000) MB, corrupted \(s.demuxCorrupted), discontinuities \(s.demuxDiscontinuity), input \(Int(s.inputBitrate * 8000)) kbit/s")
        }
        lines.append("video tracks: " + (player.videoTracks.map(\.trackName).joined(separator: ", ").nilIfEmpty ?? "none"))
        lines.append("audio tracks: " + (audioTracks.map { "\($0.name)\($0.id == currentAudioTrack ? " ✓" : "")" }.joined(separator: ", ").nilIfEmpty ?? "none"))
        lines.append("subtitle tracks: " + (subtitleTracks.map { "\($0.name)\($0.id == currentSubtitleTrack ? " ✓" : "")" }.joined(separator: ", ").nilIfEmpty ?? "none"))
        lines.append("chapters: \(chapters.count), picture in picture: \(isPictureInPictureActive)")
        lines.append("thermal: \(ProcessInfo.processInfo.thermalState.rawValue), low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        lines.append("")
        lines.append("events:")
        lines.append(contentsOf: events)
        return lines.joined(separator: "\n")
    }
    private var rebuilds = 0
    private var probed = false
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

    /// Replaced by `rebuildPlayer` when libvlc wedges (an input that never finishes stopping leaves
    /// every later open hanging); everything that holds a reference reads it through here.
    public private(set) var player = VLCMediaPlayer()
    private var openTimeouts = 0
    /// The object VLCKit's PiP window drives for play/pause/seek. `VLCVideoView` returns it from
    /// `mediaController()`; it talks to `player` directly because PiP calls arrive off the main actor.
    public let pictureInPictureMediaController: VLCPictureInPictureMediaControlling
    private var pipMediaController: PiPMediaController { pictureInPictureMediaController as! PiPMediaController }

    /// A fresh VLCMediaPlayer wired like the old one. libvlc stops asynchronously; an SMB input stuck in
    /// a read sometimes never finishes, and the player then serialises every later open behind it,
    /// so the only way out is a new player. The drawable and PiP bridge move across.
    private func rebuildPlayer(reason: String) {
        rebuilds += 1
        let old = player
        let drawable = old.drawable
        old.delegate = nil
        old.stop()
        // Releasing the old player deallocates it, and VLCMediaPlayer's dealloc joins the input thread.
        // A wedged input never ends, so that join blocked the main thread until iOS killed the app
        // (0x8BADF00D). The last reference is dropped on a background thread instead; if the input
        // never finishes, that thread stays parked and the player leaks, which is the lesser evil.
        Task.detached(priority: .background) { [old] in
            try? await Task.sleep(for: .seconds(2))
            _ = old
        }
        player = VLCMediaPlayer()
        player.delegate = self
        player.drawable = drawable
        pipMediaController.player = player
        pipController = nil
        canStartPictureInPicture = false
        isPictureInPictureActive = false
        log("rebuilt VLC player: \(reason)")
    }

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
        recoveries = 0
        openTimeouts = 0
        performLoad(item, options: options)
    }

    /// How many times the stream has been reopened on its own since the last `load`. Two reconnects
    /// with no joy means the server is really gone; the viewer gets the error card and Retry instead.
    private var recoveries = 0

    /// Reopens the current stream at the current position: a fresh VLC input and, for SMB and WebDAV,
    /// a fresh connection. Used when the stream dies mid-play (a NAS that dropped the session, Wi-Fi
    /// that came and went); the alternative was a player spinning on a dead socket forever.
    private func reconnect(at position: TimeInterval? = nil) {
        guard var current = item else { return }
        guard recoveries < 2 else {
            let host = current.url.host.map { " to \($0)" } ?? ""
            log("gave up reconnecting\(host)")
            stopRequested = true
            player.stop()
            setStatus(.failed("Lost the connection\(host) and couldn't get it back. Check the server, then retry."))
            return
        }
        recoveries += 1
        current.startAt = max(0, position ?? clock.time)
        log("reconnect \(recoveries)/2 at \(Int(current.startAt))s: \(Diagnostics.safe(current.url))")
        performLoad(current, options: options)
    }

    private func performLoad(_ item: PlaybackItem, options: PlaybackOptions) {
        stop()
        if player.state == .stopping { rebuildPlayer(reason: "previous input still stopping") }
        log("load \(Diagnostics.safe(item.url)) startAt=\(Int(item.startAt))s hw=\(options.hardwareDecoding) cache=\(options.networkCachingMS)ms")
        self.item = item
        self.options = options
        tracksLoaded = false
        probed = false
        appliedStart = false
        resumeConfirmed = false
        resumeAttempts = 0
        userChoseSubtitle = false
        stopRequested = false
        hasPlayed = false

        guard let media = VLCMedia(url: item.url) else { setStatus(.failed("VLC couldn't open this URL.")); return }
        media.addOption(":network-caching=\(options.networkCachingMS)")
        media.addOption(":file-caching=1000")
        // Keep VLC's default clock. The scaffold disabled clock sync and jitter handling, which made a
        // decoder that fell behind drop every frame as late, forever, while audio played on: the
        // frozen-picture-with-sound report. Late frames are shown rather than dropped, so a slow
        // stretch catches up visibly instead of freezing.
        media.addOption(":no-drop-late-frames")
        media.addOption(":no-skip-frames")
        if options.hardwareDecoding {
            media.addOption(":codec=avcodec")
            media.addOption(":avcodec-hw=videotoolbox")
        } else {
            media.addOption(":avcodec-hw=none")
        }
        if let lang = options.preferredAudioLanguage { media.addOption(":audio-language=\(lang)") }
        // Subtitle style (freetype renderer). Set per media so a change in Settings reaches the next play.
        media.addOption(":sub-text-scale=\(options.subtitleScale)")
        media.addOption(":freetype-color=\(options.subtitleColor)")
        media.addOption(":freetype-background-opacity=\(options.subtitleBackground ? 160 : 0)")
        media.addOption(":freetype-outline-thickness=\(options.subtitleBackground ? 0 : 4)")
        if options.subtitleMargin > 0 { media.addOption(":sub-margin=\(options.subtitleMargin)") }
        // Asking VLC for a subtitle language makes it switch that track on, so only do it when subtitles
        // should be on by default; the preference is still used to pick a track when the user turns them on.
        if options.subtitlesOnByDefault, let lang = options.preferredSubtitleLanguage { media.addOption(":sub-language=\(lang)") }
        if options.dialogueBoost {
            // VLC's dynamic range compressor, set to lift quiet dialogue without letting the loud parts
            // clip: squash anything over −20 dB by 8:1 and add 12 dB back. The usual "night mode".
            media.addOption(":audio-filter=compressor")
            media.addOption(":compressor-rms-peak=0.0")
            media.addOption(":compressor-attack=25")
            media.addOption(":compressor-release=100")
            media.addOption(":compressor-threshold=-20")
            media.addOption(":compressor-ratio=8")
            media.addOption(":compressor-knee=2.5")
            media.addOption(":compressor-makeup-gain=12")
        }
        player.media = media
        loadedAt = Date()
        setStatus(.opening)
        player.play()
        for sub in item.externalSubtitles { addExternalSubtitle(sub) }
        startOpenWatchdog()
        startStallWatchdog()
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public func togglePlayPause() { player.isPlaying ? player.pause() : player.play() }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        onUserSeek?(clock.time, clamped)
        player.time = VLCTime(int: Int32(clamped * 1000))
        clock.time = clamped
        // VLC keeps reporting the old position for a few ticks after a seek; don't let those drag the
        // scrubber back before the jump lands.
        ignoreTicksUntil = Date().addingTimeInterval(0.6)
        lastSeekAt = Date()
        startSeekWatchdog(target: clamped)
    }
    private var ignoreTicksUntil = Date.distantPast
    private var lastTickAt = Date.distantPast
    private var lastSeekAt = Date.distantPast
    private var loadedAt = Date.distantPast
    private var seekWatchdog: Task<Void, Never>?
    private var openWatchdog: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?

    /// Output progress: pictures shown plus audio buffers played. VLC's clock (and so the time ticks)
    /// keeps running while the demuxer is blocked on a dead socket, so the position is no guide to a
    /// stall; this counter is. `lastProgressTime` is where the picture actually froze, which is where
    /// a reconnect should resume, not where the runaway clock got to.
    private var lastProgressCount = 0
    private var lastProgressAt = Date.distantPast
    private var lastProgressTime: TimeInterval = 0
    /// Pictures alone: a stalled video decoder leaves the audio running, which the combined count
    /// would read as progress. Ten seconds without a new picture while audio advances is a video stall.
    private var lastPictures = 0
    private var lastPicturesAt = Date.distantPast
    private var lastPicturesTime: TimeInterval = 0

    /// Coming back to the foreground (after PiP, the lock screen or another app): if VLC says it is
    /// playing but nothing reaches the output within a few seconds, the socket died while we were away.
    /// Reconnect now rather than leaving the viewer to wait for the 15 s stall watchdog.
    public func verifyPlaybackAfterForeground() {
        guard status == .playing, let stats = player.media?.statistics else { return }
        let before = Int(stats.displayedPictures) + Int(stats.playedAudioBuffers)
        let position = clock.time
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.status == .playing, let now = self.player.media?.statistics else { return }
            let after = Int(now.displayedPictures) + Int(now.playedAudioBuffers)
            if after == before {
                log("no output since returning to the foreground; reconnecting at \(Int(position))s")
                self.reconnect(at: position)
            }
        }
    }

    /// If nothing has been shown or played for 15 s while VLC still claims to be playing, the connection
    /// has died underneath it (VLC itself waits forever): reopen at the last position that played.
    /// Paused, the end of the stream and seeks are left alone; the seek watchdog has its own recovery.
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        lastProgressCount = 0
        lastProgressAt = Date()
        lastPictures = 0
        lastPicturesAt = Date()
        stallWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Reading VLC's statistics is cheap, but a hot device gets left alone as much as possible.
                let hot: Bool = { switch ProcessInfo.processInfo.thermalState { case .serious, .critical: true; default: false } }()
                try? await Task.sleep(for: .seconds(hot ? 15 : 5))
                guard let self, !Task.isCancelled else { return }
                guard self.status == .playing, let stats = self.player.media?.statistics else { continue }
                let pictures = Int(stats.displayedPictures)
                let count = pictures + Int(stats.playedAudioBuffers)
                if pictures != self.lastPictures {
                    self.lastPictures = pictures; self.lastPicturesAt = Date(); self.lastPicturesTime = self.clock.time
                } else if !self.player.videoTracks.isEmpty, count != self.lastProgressCount,
                          Date().timeIntervalSince(self.lastPicturesAt) > 6, Date().timeIntervalSince(self.lastSeekAt) > 15,
                          !self.isPictureInPictureActive {
                    log("video stalled: no picture for \(Int(Date().timeIntervalSince(self.lastPicturesAt)))s while audio ran (decoded \(stats.decodedVideo), shown \(stats.displayedPictures), lost \(stats.lostPictures), read \(stats.demuxReadBytes / 1_000_000) MB); reloading at \(Int(self.lastPicturesTime))s")
                    self.reconnect(at: self.lastPicturesTime)
                    continue
                }
                if count != self.lastProgressCount {
                    self.lastProgressCount = count
                    self.lastProgressAt = Date()
                    self.lastProgressTime = self.clock.time
                    continue
                }
                if Date().timeIntervalSince(self.lastProgressAt) > 15, Date().timeIntervalSince(self.lastSeekAt) > 15 {
                    log("stalled: no output for \(Int(Date().timeIntervalSince(self.lastProgressAt)))s, clock says \(Int(self.clock.time))s, last played \(Int(self.lastProgressTime))s")
                    self.reconnect(at: self.lastProgressTime)
                }
            }
        }
    }

    /// libvlc never times out an open on its own: an SMB server that has gone away, or a Wi-Fi link that
    /// dropped while the app was in the background, leaves the input thread blocked in the network with
    /// the spinner up and no way to retry. VLC even reports "buffering/playing" while blocked, so the
    /// test is whether a single position tick has arrived since the load, not the state. After 20 s
    /// without one, stop (which interrupts the blocked open) and report which host did not answer.
    private func startOpenWatchdog() {
        openWatchdog?.cancel()
        let issuedAt = Date()
        openWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.lastTickAt < issuedAt else { return }
            guard self.status != .paused, self.status != .idle, self.status != .ended else { return }
            if case .failed = self.status { return }
            let target = self.item?.url.host.map { "on \($0)" } ?? "the file"
            log("open timed out after 20s \(target)")
            self.openTimeouts += 1
            if self.openTimeouts == 1, let current = self.item {
                // First timeout: assume the player wedged (it usually has, when the share answered the
                // pre-flight connect) and try once more on a fresh one before blaming the server.
                self.rebuildPlayer(reason: "open timed out")
                self.performLoad(current, options: self.options)
                return
            }
            self.stopRequested = true
            self.player.stop()
            self.setStatus(.failed("No response opening \(target) after 20 seconds. Check the server is on and reachable, then retry."))
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
                log("seek to \(Int(target))s never landed; reloading there")
                current.startAt = target
                self.performLoad(current, options: self.options)
            }
            self.seekWatchdog = nil
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

    /// `select` switches to the file once VLC has added it as a track (it arrives through the track
    /// callbacks a moment later), for a subtitle the viewer just downloaded.
    public func addExternalSubtitle(_ url: URL) { addExternalSubtitle(url, select: false) }
    public func addExternalSubtitle(_ url: URL, select: Bool) {
        if select { userChoseSubtitle = true; selectNextAddedSubtitle = true }
        player.addPlaybackSlave(url, type: .subtitle, enforce: select)
    }
    private var selectNextAddedSubtitle = false

    public func stop() {
        seekWatchdog?.cancel(); seekWatchdog = nil
        openWatchdog?.cancel()
        stallWatchdog?.cancel()
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
        case .buffering: setStatus(player.isPlaying && lastTickAt >= loadedAt ? .playing : .buffering)
        case .playing:
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
            // A stop well short of the end is the stream dying (the server dropped the connection),
            // not the film finishing: reopen where we were rather than marking it watched.
            if state == .stopped, duration > 0, duration - time > 20 { log("stream stopped \(Int(duration - time))s before the end"); reconnect(); break }
            setStatus(.ended)
            canStartPictureInPicture = false
        case .error:
            log("VLC error state (hasPlayed=\(hasPlayed))")
            if hasPlayed, time > 0 { reconnect() } else { setStatus(.failed("VLC couldn't play this file.")) }
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
        openWatchdog?.cancel()
        // Half a minute of steady playback after a reconnect earns a fresh allowance for the next drop.
        if recoveries > 0, Date().timeIntervalSince(loadedAt) > 30 { recoveries = 0 }
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
        if !probed, let key = item?.itemKey, !newAudio.isEmpty || !player.videoTracks.isEmpty {
            probed = true
            let video = player.videoTracks.first.map { $0.codecName() }
            let audio = newAudio.map { [$0.codec, $0.channels.map { Self.channelLabel($0) }].compactMap { $0 }.joined(separator: " ") }.filter { !$0.isEmpty }
            let subs = newSubs.isEmpty ? nil : "\(newSubs.count) embedded" + (newSubs.compactMap(\.language).isEmpty ? "" : " (" + Array(Set(newSubs.compactMap(\.language))).sorted().joined(separator: ", ") + ")")
            onProbe?(key, Probe(videoCodec: video?.isEmpty == false ? video : nil, audio: audio.isEmpty ? nil : Array(Set(audio)).joined(separator: " · "), subtitles: subs, duration: clock.duration))
        }
        if newSubs.count > subtitleTracks.count, selectNextAddedSubtitle, let last = newSubs.last {
            selectNextAddedSubtitle = false
            subtitleTracks = newSubs
            applySubtitleTrack(last.id)
        }
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

    static func channelLabel(_ n: Int) -> String { switch n { case 1: "mono"; case 2: "2.0"; case 6: "5.1"; case 8: "7.1"; default: "\(n)ch" } }

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
    var player: VLCMediaPlayer
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
