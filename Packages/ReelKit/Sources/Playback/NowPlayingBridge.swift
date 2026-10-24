#if canImport(MediaPlayer) && canImport(UIKit)
import Foundation
import UIKit
import MediaPlayer
import AVFoundation
import Combine

/// Lock screen / Control Centre integration for whichever engine is active.
@MainActor
public final class NowPlayingBridge {
    private var cancellables: Set<AnyCancellable> = []
    private weak var engine: (any PlaybackEngine)?

    public init() {}

    public func attach<E: PlaybackEngine>(_ engine: E, title: String, subtitle: String?, artwork: UIImage?) {
        self.engine = engine
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak engine] _ in engine?.play(); return .success }
        center.pauseCommand.addTarget { [weak engine] _ in engine?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak engine] _ in engine?.togglePlayPause(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak engine] _ in engine?.skip(by: 10); return .success }
        center.skipBackwardCommand.addTarget { [weak engine] _ in engine?.skip(by: -10); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak engine] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            engine?.seek(to: e.positionTime); return .success
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // Once a second is plenty for the lock screen; per-tick updates are an IPC round trip each.
        engine.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let engine else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyPlaybackDuration] = engine.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.time
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.status == .playing ? engine.rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func detach() {
        cancellables.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
    }
}
#endif
