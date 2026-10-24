import SwiftUI
import AVKit
import MediaCore
import Library

/// Apple's own player, used when AirPlay is the active route and the file is one AVFoundation can
/// stream natively (MP4, M4V, MOV over HTTP or from a download). That gives true AirPlay streaming,
/// where VLCKit can only mirror the screen. MKV and SMB still go through VLC.
struct NativePlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerCoordinator
    let playback: PlayerCoordinator.NativePlayback
    @State private var avPlayer: AVPlayer?

    var body: some View {
        NativePlayerController(player: avPlayer, onDismiss: { finish() })
            .ignoresSafeArea()
            .onAppear {
                let p = AVPlayer(url: playback.url)
                p.allowsExternalPlayback = true
                p.usesExternalPlaybackWhileExternalScreenIsActive = true
                if playback.startAt > 0 { p.seek(to: CMTime(seconds: playback.startAt, preferredTimescale: 600)) }
                p.play()
                avPlayer = p
                Diagnostics.log("player", "native AirPlay playback of \(Diagnostics.safe(playback.url))")
            }
            .onDisappear { finish() }
    }

    private func finish() {
        guard let p = avPlayer else { return }
        let pos = p.currentTime().seconds
        let dur = p.currentItem?.duration.seconds ?? 0
        if dur.isFinite, dur > 0 { library.recordProgress(itemKey: playback.itemKey, position: pos, duration: dur) }
        p.pause()
        avPlayer = nil
        player.nativePlayback = nil
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer?
    let onDismiss: () -> Void
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) { if vc.player !== player { vc.player = player } }
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
    }
}
