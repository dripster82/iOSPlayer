#if canImport(UIKit)
import Foundation
import UIKit
import VLCKit
import MediaCore

/// Live frames while scrubbing, the way Infuse does it on a plain share: a second, muted VLC player
/// on the same file is seeked to wherever the finger is and paints into the preview bubble. The
/// thumbnail strip stays underneath until the first live picture lands, and between seeks the last
/// live picture stays up, so the bubble is never empty. The player is kept paused for a while after
/// a scrub so the next drag starts at once, then stopped to release the connection.
///
/// The preview is a still, not a playing picture: each seek lets the player run only until the
/// first frame at the new position has been shown, then pauses it there. (A seek on a paused
/// libvlc 4 player does not repaint, so it has to run for that one tick.)
@MainActor
public final class ScrubPreview: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    public static let shared = ScrubPreview()

    /// A new player per open: stop in libvlc 4 is asynchronous, and reusing the player right after
    /// a stop (new media, play) raced the old input and left the bubble black.
    private var player = VLCMediaPlayer()
    /// The one view VLC ever paints into. The bubble re-parents it; handing VLC a new drawable for
    /// each bubble left its output bound to the old, gone view, which is the other black bubble.
    public let canvas: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        return v
    }()
    private var url: URL?
    private var target: TimeInterval?
    private var seeking: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    /// True once a frame of the current open has been shown.
    @Published public private(set) var hasPicture = false
    /// The time the last shown frame came from, so the view can fade when it is far from the finger.
    @Published public private(set) var shownTime: TimeInterval = 0
    private var hardwareDecoding = true
    /// Runs after each seek: waits for the player to reach the target, then pauses it and makes sure
    /// the pause stuck. VLC reports the old position for a few ticks after a seek, so pausing on the
    /// first tick stopped the player before the seek landed, or not at all.
    private var settling: Task<Void, Never>?
    private var settleTarget: TimeInterval?

    private override init() {
        super.init()
        player.delegate = self
        player.drawable = canvas
    }

    /// A drag began at `time` on `url`. Opens (or resumes) the preview player there.
    public func begin(url: URL, at time: TimeInterval, hardwareDecoding: Bool) {
        idle?.cancel(); idle = nil
        self.hardwareDecoding = hardwareDecoding
        // Resume whatever is still open on this file (paused after the last drag, or mid-settle).
        if self.url == url, player.media != nil, player.state != .stopped, player.state != .error {
            scrub(to: time)
            return
        }
        open(url: url, at: time)
    }

    private func open(url: URL, at time: TimeInterval) {
        self.url = url
        hasPicture = false
        target = nil
        settling?.cancel(); settling = nil
        if player.media != nil {
            let old = player
            old.delegate = nil
            old.drawable = nil
            if old.state != .stopped { old.stop() }
            // Released off the main thread: dealloc joins the input thread, which can block on a share.
            Task.detached(priority: .background) { [old] in try? await Task.sleep(for: .seconds(2)); _ = old }
            player = VLCMediaPlayer()
            player.delegate = self
            player.drawable = canvas
        }
        guard let media = VLCMedia(url: url) else { return }
        // Position zero of this open is the wanted time: libvlc 4 drops seeks issued before playback.
        media.addOption(":start-time=\(Int(time))")
        media.addOption(":no-audio")
        media.addOption(":network-caching=400")
        media.addOption(":file-caching=300")
        media.addOption(hardwareDecoding ? ":avcodec-hw=videotoolbox" : ":avcodec-hw=none")
        player.media = media
        player.play()
        settle(at: time)   // show the first frame, then hold it
        Diagnostics.log("player", "scrub preview opened at \(Int(time))s")
    }

    /// The finger moved. Seeks are coalesced to one every 150 ms; the player must be playing for a
    /// seek to take, so an open that has not started yet applies the latest target when it does.
    public func scrub(to time: TimeInterval) {
        target = time
        guard seeking == nil else { return }
        seeking = Task { @MainActor [weak self] in
            defer { self?.seeking = nil }
            try? await Task.sleep(for: .milliseconds(150))
            self?.applyTarget()
        }
    }

    private func applyTarget() {
        guard let t = target, player.isSeekable, player.state == .playing || player.state == .paused else { return }
        target = nil
        // Seek, run until the frame at the new position is shown, then hold it.
        player.time = VLCTime(int: Int32(t * 1000))
        if !player.isPlaying { player.play() }
        settle(at: t)
    }

    private func settle(at target: TimeInterval) {
        settling?.cancel()
        settleTarget = target
        settling = Task { @MainActor [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                let now = TimeInterval(self.player.time.intValue) / 1000
                let landed = abs(now - target) < 2.5
                // Pause once the seek has landed, or after a second regardless (a keyframe far away).
                if landed || Date().timeIntervalSince(started) > 1.2 {
                    if self.player.isPlaying { self.player.pause() }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    if self.player.isPlaying { self.player.pause() }   // pause issued mid-seek can be lost
                    self.settling = nil
                    return
                }
            }
        }
    }

    /// The drag ended: the picture stays, the player pauses, and after a while stops.
    public func end() {
        target = nil
        if player.isPlaying, settling == nil { player.pause() }
        idle?.cancel()
        idle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Releases the stream (the player was dismissed, or the preview went idle).
    public func stop() {
        idle?.cancel(); idle = nil
        seeking?.cancel(); seeking = nil
        settling?.cancel(); settling = nil
        target = nil
        if player.state != .stopped { player.stop() }
        url = nil
        hasPicture = false
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            let t = TimeInterval(self.player.time.intValue) / 1000
            if !self.hasPicture { self.hasPicture = true }
            if abs(t - self.shownTime) >= 0.5 { self.shownTime = t }
            // A seek issued while the player was still opening is applied on the first tick.
            if self.target != nil, self.seeking == nil { self.applyTarget() }
        }
    }

    nonisolated public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            if newState == .playing, self.target != nil, self.seeking == nil { self.applyTarget() }
        }
    }
}
#endif
