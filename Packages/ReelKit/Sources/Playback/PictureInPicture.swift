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
    /// When the window last asked for a skip, and whether the video was playing then. AVKit sends
    /// a pause (twice) right after the skip it asked for; the video is left as it was instead.
    private var lastSkipAt = Date.distantPast
    private var playingAtSkip = false
    /// The pause that comes a hair *before* the skip (same millisecond on the iPad): noted here,
    /// and undone once the skip arrives, since the viewer asked to skip, not to stop.
    private var lastPauseAt = Date.distantPast
    private var playingBeforePause = false
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

    /// The window reads the position only when told the state changed, and its "now" comes from
    /// the layer's timebase, which VLC does not necessarily run; so every noticeable move of the
    /// position (the ticks come several times a second) invalidates, and the range is placed
    /// afresh each time. That keeps the window's timeline moving and the skips landing.
    @MainActor
    func update(playing: Bool, time: TimeInterval, duration: TimeInterval) {
        let changed: Bool = lock.withLock {
            let was = snapshot
            snapshot = Snapshot(playing: playing, time: time, duration: duration)
            return was.playing != playing || abs(was.time - time) >= 0.5 || was.duration != duration
        }
        if changed, controller?.isPictureInPictureActive == true { controller?.invalidatePlaybackState() }
    }

    /// A fresh controller over the same layer. After the app comes back from the background with
    /// no window open, the display layer reports itself failed ("Operation Interrupted"); a flush
    /// has it painting again, but the controller made over it never starts a window after that
    /// (an iPad log: every swipe-up "Failed to start picture in picture" from then on, where each
    /// one before had worked). Nothing to do while a window is open.
    @MainActor
    func rebuild(reason: String) {
        guard let layer, controller?.isPictureInPictureActive != true else { return }
        controller = nil
        self.layer = nil
        log?("PiP: controller made afresh (\(reason))")
        attach(layer)
    }

    @MainActor func start() { controller?.startPictureInPicture() }
    @MainActor func stop() { controller?.stopPictureInPicture() }
}

extension ReelPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            if !playing, Date().timeIntervalSince(self.lastSkipAt) < 2, self.playingAtSkip {
                self.log?("PiP: pause right after the skip ignored")
                self.controller?.invalidatePlaybackState()
                return
            }
            if !playing { self.lastPauseAt = Date(); self.playingBeforePause = self.lock.withLock { self.snapshot.playing } }
            self.onSetPlaying?(playing)
        }
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
        Task { @MainActor in
            let pausedForThis = Date().timeIntervalSince(self.lastPauseAt) < 0.5 && self.playingBeforePause
            self.lastSkipAt = Date(); self.playingAtSkip = self.lock.withLock { self.snapshot.playing } || pausedForThis
            self.log?("PiP: skip by \(Int(seconds))s\(pausedForThis ? " (undoing the pause that came with it)" : "")")
            self.onSkip?(seconds)
            if pausedForThis { self.onSetPlaying?(true) }
            completionHandler()
            self.controller?.invalidatePlaybackState()
        }
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
