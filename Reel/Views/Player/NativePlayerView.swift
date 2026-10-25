import SwiftUI
import AVKit
import MediaCore
import Library

/// Apple's own player, used when AirPlay is the active route: MP4, M4V and MOV directly (from a
/// download, an HTTP URL, or a share through the local bridge), and MKV after a remux to MP4. Apple's
/// player is the only path that sends the picture, not just the sound, over AirPlay.
struct NativePlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    let playback: PlayerCoordinator.NativePlayback
    @State private var avPlayer: AVPlayer?
    @State private var endWatcher: Any?
    @State private var statusWatcher: NSKeyValueObservation?
    @State private var heartbeat: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            NativePlayerController(player: avPlayer)
                .ignoresSafeArea()
            // Apple's controller puts its own buttons in the corners (Picture in Picture, AirPlay, the
            // audio and subtitle menu) and has no close button or chapter list when embedded, so what
            // Reel adds sits in the top centre, clear of them.
            HStack(spacing: 10) {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Close")
                VStack(spacing: 1) {
                    Text(playback.title).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if !playback.subtitle.isEmpty { Text(playback.subtitle).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                }
                if !playback.chapters.isEmpty {
                    Menu {
                        ForEach(playback.chapters) { c in
                            Button { seek(to: c.start) } label: { Label(c.title, systemImage: isCurrent(c) ? "checkmark" : "bookmark") }
                        }
                    } label: {
                        Label("Chapters", systemImage: "list.bullet").labelStyle(.iconOnly).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Chapters")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: Capsule())
            .frame(maxWidth: 420)
            .padding(.top, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            // SwiftUI can build this view more than once for one presentation; the player is made once.
            guard avPlayer == nil else { return }
            let item = AVPlayerItem(url: playback.url)
            // The title and episode show in the controls and on the TV's now-playing display.
            item.externalMetadata = [metadata(.commonIdentifierTitle, playback.title), metadata(.iTunesMetadataTrackSubTitle, playback.subtitle)].compactMap { $0 }
            let p = AVPlayer(playerItem: item)
            p.allowsExternalPlayback = true
            p.usesExternalPlaybackWhileExternalScreenIsActive = true
            if playback.startAt > 0 { p.seek(to: CMTime(seconds: playback.startAt, preferredTimescale: 600)) }
            p.play()
            avPlayer = p
            endWatcher = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in close(markWatched: true) }
            // Why a black screen, when it is one: the item's status and error go to the log.
            statusWatcher = p.currentItem?.observe(\.status, options: [.new]) { item, _ in
                let message = item.error.map { " error: \(String(describing: $0))" } ?? ""
                Diagnostics.log("player", "native item status \(item.status.rawValue)\(message)")
                for ev in item.errorLog()?.events ?? [] { Diagnostics.log("player", "native error log \(ev.errorStatusCode) \(ev.errorComment ?? "") \(ev.uri ?? "")") }
            }
            Diagnostics.log("player", "native AirPlay playback of \(Diagnostics.safe(playback.url))")
            // A heartbeat for the log: is the picture going to the receiver, and what is the player waiting on?
            heartbeat = Task { @MainActor in
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let p = avPlayer else { return }
                    let t = p.currentTime().seconds
                    if t.isFinite { player.nativeTime = t + playback.timeOffset }
                    ticks += 1
                    guard ticks % 5 == 0, ticks <= 120 else { continue }
                    let waiting = p.reasonForWaitingToPlay.map { " waiting: \($0.rawValue)" } ?? ""
                    let err = p.currentItem?.errorLog()?.events.last.map { " lastErr: \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? ""
                    let access = p.currentItem?.accessLog()?.events.last.map { " bytes: \($0.numberOfBytesTransferred) stalls: \($0.numberOfStalls)" } ?? ""
                    Diagnostics.log("player", "native: external=\(p.isExternalPlaybackActive) control=\(p.timeControlStatus.rawValue) t=\(Int(p.currentTime().seconds)) rate=\(p.rate) keepUp=\(p.currentItem?.isPlaybackLikelyToKeepUp ?? false)\(waiting)\(err)\(access)")
                }
            }
        }
        .onDisappear { saveProgress() }
    }

    private func metadata(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
        guard !value.isEmpty else { return nil }
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    /// Chapter starts are in the file's own time; the stream's clock may begin part-way in.
    private func seek(to fileTime: TimeInterval) {
        avPlayer?.seek(to: CMTime(seconds: max(0, fileTime - playback.timeOffset), preferredTimescale: 600))
    }
    private func isCurrent(_ c: Chapter) -> Bool {
        guard let t = avPlayer?.currentTime().seconds, t.isFinite else { return false }
        let now = t + playback.timeOffset
        return now >= c.start && now < c.start + c.duration
    }

    private func saveProgress(markWatched: Bool = false) {
        guard let p = avPlayer else { return }
        let pos = p.currentTime().seconds
        let dur = p.currentItem?.duration.seconds ?? 0
        // An HLS stream started part-way runs its own clock from zero; a still-growing one reports its length so far.
        if dur.isFinite, dur > 0 {
            let total = max(dur + playback.timeOffset, playback.knownDuration)
            library.recordProgress(itemKey: playback.itemKey, position: markWatched ? total : pos + playback.timeOffset, duration: total)
        }
    }

    private func close(markWatched: Bool = false) {
        saveProgress(markWatched: markWatched)
        avPlayer?.pause()
        if let w = endWatcher { NotificationCenter.default.removeObserver(w) }
        statusWatcher = nil
        heartbeat?.cancel(); heartbeat = nil
        avPlayer = nil
        player.endNativePlayback()
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer?
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) { if vc.player !== player { vc.player = player } }
}
