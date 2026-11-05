#if canImport(UIKit)
import Foundation
import AVKit
import CoreMedia

/// Reel's own Picture in Picture window over VLC's display layer.
///
/// VLCKit 4 can make a PiP controller of its own, but one per video output: the output is closed
/// when a file ends, the system window closes with it, and iOS lets nothing but the viewer open
/// one from the background, so the next episode could never follow into the window. This
/// controller is made once and lives as long as the engine; whenever VLC puts up a new display
/// layer (every load) it is handed over as the content source, and the window that is already
/// open keeps showing what the layer shows. The window's play, pause, skip and timeline come
/// through the sample-buffer playback delegate, answered from a snapshot the engine keeps fresh.
final class ReelPictureInPicture: NSObject, @unchecked Sendable {
    /// What the window asks about, kept here because AVKit asks off the main thread.
    private struct Snapshot { var playing = false, time: TimeInterval = 0, duration: TimeInterval = 0 }
    private let lock = NSLock()
    private var snapshot = Snapshot()

    private var controller: AVPictureInPictureController?
    private(set) weak var layer: AVSampleBufferDisplayLayer?
    /// Main-actor callbacks into the engine.
    var onStateChange: (@MainActor (Bool) -> Void)?
    var onSetPlaying: (@MainActor (Bool) -> Void)?
    var onSkip: (@MainActor (TimeInterval) -> Void)?
    var log: (@MainActor (String) -> Void)?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }
    var hasLayer: Bool { layer != nil }

    /// VLC's current display layer: the first one makes the controller, every later one (a new
    /// video output after a load) replaces the content source, so an open window carries on.
    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard layer !== self.layer else { return }
        self.layer = layer
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        if let controller {
            controller.contentSource = source
            log?("PiP: new display layer handed to the window (active \(controller.isPictureInPictureActive))")
        } else {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { log?("PiP: not supported here"); return }
            let c = AVPictureInPictureController(contentSource: source)
            c.delegate = self
            c.canStartPictureInPictureAutomaticallyFromInline = true
            controller = c
            log?("PiP: controller made over VLC's display layer")
        }
        controller?.invalidatePlaybackState()
    }

    @MainActor
    func update(playing: Bool, time: TimeInterval, duration: TimeInterval) {
        let changed: Bool = lock.withLock {
            let was = snapshot.playing
            snapshot = Snapshot(playing: playing, time: time, duration: duration)
            return was != playing
        }
        if changed { controller?.invalidatePlaybackState() }
    }

    @MainActor func start() { controller?.startPictureInPicture() }
    @MainActor func stop() { controller?.stopPictureInPicture() }
}

extension ReelPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.onSetPlaying?(playing) }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let s = lock.withLock { snapshot }
        guard s.duration > 0 else { return CMTimeRange(start: .zero, duration: .positiveInfinity) }
        // The window reads "now" from the layer's timebase; the range is placed so that now falls
        // at the current position, which puts the timeline's knob in the right place.
        let now = layer.map { CMTimebaseGetTime($0.timebase) } ?? .zero
        let start = CMTimeSubtract(now, CMTime(seconds: s.time, preferredTimescale: 1000))
        return CMTimeRange(start: start, duration: CMTime(seconds: s.duration, preferredTimescale: 1000))
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !lock.withLock { snapshot.playing }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let seconds = CMTimeGetSeconds(skipInterval)
        Task { @MainActor in self.onSkip?(seconds); completionHandler() }
    }
}

extension ReelPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.log?("PiP started"); self.onStateChange?(true) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.log?("PiP ended"); self.onStateChange?(false) }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.log?("PiP could not start: \(error.localizedDescription)") }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif
