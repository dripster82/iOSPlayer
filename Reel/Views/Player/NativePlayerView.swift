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
            // Apple's controller has no close button, title or chapter list of its own when embedded.
            HStack(alignment: .top, spacing: 12) {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(Color.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel("Close")
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if !playback.subtitle.isEmpty { Text(playback.subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                    Label("AirPlay", systemImage: "airplayvideo").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if playback.audioTracks.count > 1 {
                    Menu {
                        ForEach(Array(playback.audioTracks.enumerated()), id: \.offset) { i, track in
                            Button { changeAudio(to: i) } label: { Label(track.name, systemImage: i == (playback.audioTrack ?? 0) ? "checkmark" : "waveform") }
                        }
                    } label: {
                        Text("Audio").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.15), in: Capsule())
                    }
                }
                if !playback.chapters.isEmpty {
                    Menu {
                        ForEach(playback.chapters) { c in
                            Button { seek(to: c.start) } label: { Label(c.title, systemImage: isCurrent(c) ? "checkmark" : "bookmark") }
                        }
                    } label: {
                        Text("Chapters").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.15), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 14)
            .shadow(radius: 4)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            // SwiftUI can build this view more than once for one presentation; the player is made once.
            guard avPlayer == nil else { return }
            let p = AVPlayer(url: playback.url)
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

    /// Another audio track means another copy from VLC: a few seconds' gap, then on from here.
    private func changeAudio(to index: Int) {
        guard index != (playback.audioTrack ?? 0) else { return }
        let now = (avPlayer?.currentTime().seconds ?? 0) + playback.timeOffset
        saveProgress()
        avPlayer?.pause()
        player.selectNativeAudio(index, at: now, settings: settings)
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
