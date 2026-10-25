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
    let playback: PlayerCoordinator.NativePlayback
    @State private var avPlayer: AVPlayer?
    @State private var endWatcher: Any?
    @State private var statusWatcher: NSKeyValueObservation?

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativePlayerController(player: avPlayer)
                .ignoresSafeArea()
            // The embedded controller has no close button of its own.
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(Color.white.opacity(0.15), in: Circle())
            }
            .padding(.leading, 20).padding(.top, 14)
            .accessibilityLabel("Close")
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
        }
        .onDisappear { saveProgress() }
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
