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
    @Published public private(set) var time: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var rate: Float = 1
    @Published public private(set) var audioTracks: [MediaTrack] = []
    @Published public private(set) var subtitleTracks: [MediaTrack] = []
    @Published public private(set) var currentAudioTrack: Int?
    @Published public private(set) var currentSubtitleTrack: Int?
    @Published public private(set) var chapters: [Chapter] = []
    @Published public private(set) var subtitleDelay: TimeInterval = 0
    @Published public private(set) var audioDelay: TimeInterval = 0

    /// True once VLC's video output has offered a Picture in Picture controller for the current media.
    @Published public private(set) var canStartPictureInPicture = false
    /// True while the system PiP window is showing the video.
    @Published public private(set) var isPictureInPictureActive = false

    public let player = VLCMediaPlayer()
    /// The object VLCKit's PiP window drives for play/pause/seek. `VLCVideoView` returns it from
    /// `mediaController()`; it talks to `player` directly because PiP calls arrive off the main actor.
    public let pictureInPictureMediaController: VLCPictureInPictureMediaControlling

    private weak var pipController: (any VLCPictureInPictureWindowControlling)?
    private var item: PlaybackItem?
    private var options = PlaybackOptions()
    private var tracksLoaded = false
    private var appliedStart = false
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
        stopRequested = false
        hasPlayed = false

        guard let media = VLCMedia(url: item.url) else { status = .failed("VLC couldn't open this URL."); return }
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
        if let lang = options.preferredSubtitleLanguage { media.addOption(":sub-language=\(lang)") }
        player.media = media
        status = .opening
        player.play()
        for sub in item.externalSubtitles { addExternalSubtitle(sub) }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public func togglePlayPause() { player.isPlaying ? player.pause() : player.play() }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.time = VLCTime(int: Int32(clamped * 1000))
        time = clamped
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
        if player.state != .stopped {
            stopRequested = true
            player.stop()
        }
        status = .idle
        time = 0
        duration = 0
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

    /// Fit letterboxes inside the drawable (VLC's default). Fill crops the picture to the drawable's
    /// aspect ratio so it covers the screen. VLCKit 4 replaced the `videoCropGeometry` string with a
    /// crop *ratio*, which is all Fill ever needed (points vs pixels doesn't matter for a ratio).
    public func setFill(_ fill: Bool) {
        fillEnabled = fill
        applyFill()
    }

    /// Re-applies the current Fit/Fill choice. `VLCVideoView` calls it whenever the drawable is laid out.
    public func drawableDidLayout() { applyFill() }

    private func applyFill() {
        player.scaleFactor = 0
        guard fillEnabled, let view = player.drawable as? PlatformView else { player.setCropRatioWithNumerator(0, denominator: 0); return }
        let w = UInt32(view.bounds.width.rounded()), h = UInt32(view.bounds.height.rounded())
        guard w > 0, h > 0 else { player.setCropRatioWithNumerator(0, denominator: 0); return }
        player.setCropRatioWithNumerator(w, denominator: h)
    }

    // MARK: - Picture in Picture

    /// Called by the drawable's `pictureInPictureReady` block. VLC creates one controller per video
    /// output, so this fires on every `load` once the first frame is up and the reference dies with it.
    public func pictureInPictureDidBecomeAvailable(_ controller: any VLCPictureInPictureWindowControlling) {
        pipController = controller
        controller.stateChangeEventHandler = { [weak self] started in
            Task { @MainActor in self?.isPictureInPictureActive = started }
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

    // MARK: - VLCMediaPlayerDelegate

    nonisolated public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in self.handleStateChange(newState) }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleTimeChange() }
    }

    nonisolated public func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor in
            if length > 0 { self.duration = TimeInterval(length) / 1000 }
            self.pipController?.invalidatePlaybackState()
        }
    }

    nonisolated public func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in if !self.tracksLoaded { self.loadTracks() } }
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
        case .opening: status = .opening
        case .buffering: status = player.isPlaying ? .playing : .buffering
        case .playing:
            status = .playing
            hasPlayed = true
            if !tracksLoaded { loadTracks() }
            if !appliedStart, let start = item?.startAt, start > 0 {
                appliedStart = true
                seek(to: start)
            }
        case .paused: status = .paused
        case .stopping, .stopped:
            // VLC 4 has no "ended" state: a stream that runs out goes stopping → stopped on its own.
            // Only our own `stop()` sets `stopRequested`, so anything else after playback began is the
            // end. `hasPlayed` also filters the stop events of the *previous* media, which can land
            // after `load()` has already moved on (stop is asynchronous in libvlc 4).
            guard !stopRequested, hasPlayed else { break }
            status = .ended
            canStartPictureInPicture = false
        case .error: status = .failed("VLC couldn't play this file.")
        @unknown default: break
        }
    }

    private func handleTimeChange() {
        time = TimeInterval(player.time.intValue) / 1000
        if let length = player.media?.length.intValue, length > 0 { duration = TimeInterval(length) / 1000 }
        if !tracksLoaded, time > 0.5 { loadTracks() }
        if status == .buffering { status = .playing }
    }

    /// Track lists are only reliable once the ES have been added, so this runs lazily and re-runs
    /// until it finds something.
    private func loadTracks() {
        vlcAudioTracks = player.audioTracks
        vlcSubtitleTracks = player.textTracks

        audioTracks = vlcAudioTracks.enumerated().map { i, t in
            MediaTrack(id: i, name: t.trackName, language: t.language ?? Self.language(in: t.trackName), codec: t.codecName(), channels: t.audio.map { Int($0.channelsNumber) })
        }
        subtitleTracks = vlcSubtitleTracks.enumerated().map { i, t in
            MediaTrack(id: i, name: t.trackName, language: t.language ?? Self.language(in: t.trackName), isForced: t.trackName.localizedCaseInsensitiveContains("forced"))
        }
        syncSelection()
        loadChapters()

        if !options.subtitlesOnByDefault, currentSubtitleTrack != nil, !subtitleTracks.contains(where: { $0.id == currentSubtitleTrack && $0.isForced }) {
            // Respect the user's "off by default" unless VLC picked a forced track.
            selectSubtitleTrack(nil)
        }
        tracksLoaded = !audioTracks.isEmpty
    }

    private func syncSelection() {
        currentAudioTrack = vlcAudioTracks.firstIndex(where: \.isSelected)
        currentSubtitleTrack = vlcSubtitleTracks.firstIndex(where: \.isSelected)
    }

    private func loadChapters() {
        let descs = player.chapterDescriptions(ofTitle: player.currentTitleIndex)
        chapters = descs.enumerated().map { i, d in
            Chapter(id: i, title: d.name ?? "Chapter \(i + 1)", start: TimeInterval(d.timeOffset.intValue) / 1000, duration: TimeInterval(d.durationTime.intValue) / 1000)
        }
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
