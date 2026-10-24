#if canImport(VLCKit) || canImport(MobileVLCKit)
import Foundation
import Combine
import MediaCore
#if canImport(VLCKit)
import VLCKit
#else
import MobileVLCKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// VLCKit 3.x wrapper. Owns one `VLCMediaPlayer` and republishes its state for SwiftUI.
/// The video is rendered into whatever view is assigned to `drawable` (see `VLCVideoView`).
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

    public let player = VLCMediaPlayer()
    private var item: PlaybackItem?
    private var options = PlaybackOptions()
    private var tracksLoaded = false
    private var appliedStart = false

    public override init() {
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

        let media = VLCMedia(url: item.url)
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
        player.currentAudioTrackIndex = Int32(id ?? -1)
        currentAudioTrack = id
    }

    public func selectSubtitleTrack(_ id: Int?) {
        player.currentVideoSubTitleIndex = Int32(id ?? -1)
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
        if player.isPlaying || player.state != .stopped { player.stop() }
        status = .idle
        time = 0
        duration = 0
        rate = 1
        audioTracks = []
        subtitleTracks = []
        chapters = []
        currentAudioTrack = nil
        currentSubtitleTrack = nil
    }

    /// 0 = fit (VLC default). Fill is approximated by scaling to cover the drawable.
    public func setFill(_ fill: Bool) {
        guard fill, let view = player.drawable as? PlatformView else { player.scaleFactor = 0; return }
        let size = player.videoSize
        guard size.width > 0, size.height > 0 else { player.scaleFactor = 0; return }
        let scale = max(view.bounds.width / size.width, view.bounds.height / size.height)
        player.scaleFactor = Float(scale)
    }

    // MARK: - VLCMediaPlayerDelegate

    nonisolated public func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleStateChange() }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleTimeChange() }
    }

    private func handleStateChange() {
        switch player.state {
        case .opening: status = .opening
        case .buffering: status = player.isPlaying ? .playing : .buffering
        case .playing:
            status = .playing
            if !tracksLoaded { loadTracks() }
            if !appliedStart, let start = item?.startAt, start > 0 {
                appliedStart = true
                seek(to: start)
            }
        case .paused: status = .paused
        case .stopped: if status != .idle { status = .paused }
        case .ended: status = .ended
        case .error: status = .failed("VLC couldn't play this file.")
        case .esAdded: if !tracksLoaded { loadTracks() }
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
        let aIdx = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let aNames = (player.audioTrackNames as? [String]) ?? []
        let sIdx = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let sNames = (player.videoSubTitlesNames as? [String]) ?? []

        // VLC lists "Disable" as index -1; drop it, the UI has its own Off row.
        audioTracks = zip(aIdx, aNames).compactMap { i, n in i.intValue >= 0 ? MediaTrack(id: i.intValue, name: n, language: Self.language(in: n)) : nil }
        subtitleTracks = zip(sIdx, sNames).compactMap { i, n in i.intValue >= 0 ? MediaTrack(id: i.intValue, name: n, language: Self.language(in: n), isForced: n.localizedCaseInsensitiveContains("forced")) : nil }
        currentAudioTrack = player.currentAudioTrackIndex >= 0 ? Int(player.currentAudioTrackIndex) : nil
        currentSubtitleTrack = player.currentVideoSubTitleIndex >= 0 ? Int(player.currentVideoSubTitleIndex) : nil

        if let descs = player.chapterDescriptions(ofTitle: player.currentTitleIndex) as? [[String: Any]] {
            chapters = descs.enumerated().map { i, d in
                let name = (d[VLCChapterDescriptionName] as? String) ?? "Chapter \(i + 1)"
                let offset = ((d[VLCChapterDescriptionTimeOffset] as? NSNumber)?.doubleValue ?? 0) / 1000
                let dur = ((d[VLCChapterDescriptionDuration] as? NSNumber)?.doubleValue ?? 0) / 1000
                return Chapter(id: i, title: name, start: offset, duration: dur)
            }
        }

        if !options.subtitlesOnByDefault, currentSubtitleTrack != nil, !subtitleTracks.contains(where: { $0.id == currentSubtitleTrack && $0.isForced }) {
            // Respect the user's "off by default" unless VLC picked a forced track.
            selectSubtitleTrack(nil)
        }
        tracksLoaded = !audioTracks.isEmpty
    }

    /// "Track 1 - [English]" → "English"
    private static func language(in name: String) -> String? {
        guard let open = name.lastIndex(of: "["), let close = name.lastIndex(of: "]"), open < close else { return nil }
        return String(name[name.index(after: open)..<close])
    }
}

#if canImport(UIKit)
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif
#endif
