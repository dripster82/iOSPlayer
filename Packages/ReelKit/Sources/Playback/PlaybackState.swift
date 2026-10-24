import Foundation
import MediaCore

/// Engine-independent playback state the UI binds to.
public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case opening
    case buffering
    case playing
    case paused
    case ended
    case failed(String)
}

public struct PlaybackItem: Hashable, Sendable {
    public var url: URL
    public var title: String
    public var subtitle: String?
    public var artworkURL: URL?
    public var startAt: TimeInterval
    /// Sidecar subtitle files found next to the video.
    public var externalSubtitles: [URL]
    public var itemKey: String

    public init(url: URL, title: String, subtitle: String? = nil, artworkURL: URL? = nil, startAt: TimeInterval = 0, externalSubtitles: [URL] = [], itemKey: String) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.startAt = startAt
        self.externalSubtitles = externalSubtitles
        self.itemKey = itemKey
    }
}

public struct PlaybackOptions: Sendable {
    public var hardwareDecoding = true
    /// Milliseconds of read-ahead for network streams. PLAN.md §11.2 default.
    public var networkCachingMS = 1500
    public var preferredAudioLanguage: String? = "en"
    public var preferredSubtitleLanguage: String? = "en"
    public var subtitlesOnByDefault = false
    public init() {}
}

/// What any engine must offer. Lets previews and tests run without VLC.
@MainActor
public protocol PlaybackEngine: AnyObject, ObservableObject {
    var status: PlaybackStatus { get }
    var time: TimeInterval { get }
    var duration: TimeInterval { get }
    var rate: Float { get }
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var currentAudioTrack: Int? { get }
    var currentSubtitleTrack: Int? { get }
    var chapters: [Chapter] { get }
    var subtitleDelay: TimeInterval { get }
    var audioDelay: TimeInterval { get }

    func load(_ item: PlaybackItem, options: PlaybackOptions)
    func play()
    func pause()
    func togglePlayPause()
    func seek(to seconds: TimeInterval)
    func skip(by seconds: TimeInterval)
    func setRate(_ rate: Float)
    func selectAudioTrack(_ id: Int?)
    func selectSubtitleTrack(_ id: Int?)
    func setSubtitleDelay(_ seconds: TimeInterval)
    func setAudioDelay(_ seconds: TimeInterval)
    func addExternalSubtitle(_ url: URL)
    func stop()
}

/// Playback position, published separately from the engine so that only the scrubber and clock
/// redraw on every tick. Everything else observes the engine, which changes far less often.
@MainActor
public final class PlaybackClock: ObservableObject {
    @Published public internal(set) var time: TimeInterval = 0
    @Published public internal(set) var duration: TimeInterval = 0
    public init() {}
}
