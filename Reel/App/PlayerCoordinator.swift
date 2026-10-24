import SwiftUI
import Combine
import MediaCore
import Library
import Playback
import Metadata

/// Owns the single playback engine, decides what plays next, and saves progress.
/// Presented as a full-screen cover from `RootView`.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var current: MediaItem?
    @Published private(set) var currentFile: MediaFile?
    @Published var loadError: String?
    @Published private(set) var upNext: MediaItem?
    @Published var isLoading = false
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
            case .paused: self.saveProgress()
            case .ended: self.saveProgress(markWatched: true); self.handleEnded()
            default: break
            }
        }
    }

    func play(_ item: MediaItem, file: MediaFile? = nil, fromStart: Bool = false, settings: AppSettings) {
        guard let file = file ?? library.preferredFile(item) else { loadError = "No file for \(item.title)."; return }
        current = item
        currentFile = file
        upNext = item.kind == .episode ? library.episodeAfter(item) : nil
        isPresented = true
        isLoading = true
        loadError = nil
        Task {
            do {
                let (url, subs) = try await library.playbackURL(for: file)
                let resume = fromStart ? 0 : (library.watchState(item.itemKey).map { $0.watched ? 0 : $0.position } ?? 0)
                var opts = PlaybackOptions()
                opts.hardwareDecoding = settings.hardwareDecoding
                opts.networkCachingMS = settings.networkCachingMS
                opts.preferredAudioLanguage = settings.audioLanguage
                opts.preferredSubtitleLanguage = settings.subtitleLanguage
                opts.subtitlesOnByDefault = settings.subtitlesOnByDefault
                let subtitle = item.kind == .episode ? [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ") : item.year.map(String.init)
                let playbackItem = PlaybackItem(url: url, title: item.kind == .episode ? (item.show?.title ?? item.title) : item.title, subtitle: subtitle, startAt: resume, externalSubtitles: subs, itemKey: item.itemKey)
                engine.load(playbackItem, options: opts)
                nowPlaying.attach(engine, title: playbackItem.title, subtitle: subtitle, artwork: nil)
                startSaveTimer()
                isLoading = false
            } catch {
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    /// Plays something handed to us by another app: a file URL (Files, DS file, AirDrop) or a stream URL
    /// (`reel://play?url=`). Nothing is added to the library; watch state is keyed by the URL.
    func playExternal(_ url: URL, title: String? = nil, settings: AppSettings) {
        let name = title ?? url.lastPathComponent.removingPercentEncoding ?? url.absoluteString
        let key = ItemKey.unmatched(fileName: url.absoluteString, size: 0, duration: nil)
        let item = MediaItem(itemKey: key, kind: .film, title: name, confidence: .unmatched)
        current = item
        currentFile = nil
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
        engine.load(PlaybackItem(url: url, title: name, subtitle: url.isFileURL ? nil : url.host, startAt: resume, itemKey: key), options: opts)
        nowPlaying.attach(engine, title: name, subtitle: nil, artwork: nil)
        startSaveTimer()
        isLoading = false
    }
    private var externalScopedURL: URL?

    /// Plays a file that isn't in the library (file browser).
    func playFile(_ file: MediaFile, settings: AppSettings) {
        let temp = MediaItem(itemKey: ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: nil), kind: .film, title: file.fileName, confidence: .unmatched)
        play(temp, file: file, settings: settings)
    }

    func playNext(settings: AppSettings) {
        guard let next = upNext else { dismiss(); return }
        play(next, settings: settings)
    }

    func dismiss() {
        saveProgress()
        engine.stop()
        externalScopedURL?.stopAccessingSecurityScopedResource(); externalScopedURL = nil
        nowPlaying.detach()
        saveTimer = nil
        isPresented = false
        current = nil
        currentFile = nil
    }

    // MARK: -

    private func startSaveTimer() {
        // Every 30 s during playback (PLAN.md §10.4), not every tick, to keep iCloud traffic low.
        saveTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.saveProgress() }
    }

    /// Writes the current position now (the app is about to be suspended, or the user asked).
    func flushProgress() { saveProgress() }

    private func saveProgress(markWatched: Bool = false) {
        guard let item = current, engine.duration > 0, !engine.resumePending || markWatched else { return }
        library.recordProgress(itemKey: item.itemKey, position: markWatched ? engine.duration : engine.time, duration: engine.duration)
    }

    private func handleEnded() {
        // The player view shows the Up Next card; auto-advance is its job so the countdown is visible.
        if upNext == nil { dismiss() }
    }
}
