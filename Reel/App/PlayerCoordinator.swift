import SwiftUI
import Combine
import SwiftData
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
    @Published private(set) var previous: MediaItem?
    @Published var isLoading = false
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
            case .paused: self.saveProgress()
            case .ended: self.saveProgress(markWatched: true); self.handleEnded()
            default: break
            }
        }
    }

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
                let opts = playbackOptions(for: item, settings: settings)
                let subtitle = item.kind == .episode ? [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ") : item.year.map(String.init)
                let playbackItem = PlaybackItem(url: url, title: item.kind == .episode ? (item.show?.title ?? item.title) : item.title, subtitle: subtitle, startAt: resume,
                                                externalSubtitles: subs + SubtitleStore.subtitles(for: item.itemKey), itemKey: item.itemKey)
                engine.load(playbackItem, options: opts)
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

    /// The global playback settings, overridden by what the viewer chose last time for this show
    /// (or film): the audio language, and subtitles on in a language or off.
    private func playbackOptions(for item: MediaItem, settings: AppSettings) -> PlaybackOptions {
        var opts = PlaybackOptions()
        opts.hardwareDecoding = settings.hardwareDecoding
        opts.networkCachingMS = settings.networkCachingMS
        opts.preferredAudioLanguage = settings.audioLanguage
        opts.preferredSubtitleLanguage = settings.subtitleLanguage
        opts.subtitlesOnByDefault = settings.subtitlesOnByDefault
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
        engine.load(PlaybackItem(url: url, title: name, subtitle: url.isFileURL ? nil : url.host, startAt: resume, itemKey: key), options: opts)
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
        engine.stop()
        externalScopedURL?.stopAccessingSecurityScopedResource(); externalScopedURL = nil
        nowPlaying.detach()
        saveTimer = nil
        isPresented = false
        current = nil
        currentFile = nil
        externalURL = nil
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
