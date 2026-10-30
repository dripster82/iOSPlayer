import Foundation
import CoreGraphics
import ReelVLCThumb
#if canImport(VLCKit)
import VLCKit
#endif

/// Frames from one open of a file. Opening a stream over a share costs seconds (connect, read the
/// index, seek), so the fingerprints and the intro search take all their frames from a single
/// session: a run of frames comes from playing the stretch at speed with the audio off, keeping
/// one per step as they come off the decoder; a single frame comes from a precise seek.
public final class FrameGrabber: @unchecked Sendable {
    public static var isAvailable: Bool { reel_thumb_available() }
    /// Where the grabber reports what it gave up on; the app points it at its diagnostics log.
    nonisolated(unsafe) public static var log: ((String) -> Void)?
    /// Sends the grab's libvlc messages (warnings and up) to a file, for diagnosis.
    public static func setLogPath(_ path: String?) { reel_grab_set_log_path(path) }

    private var session: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var onFrame: ((CGImage, TimeInterval) -> Void)?
    private let width: Int, height: Int
    private var unmanaged: Unmanaged<FrameGrabber>?

    /// Opens the file; nil when libvlc is not available or the stream cannot be set up.
    private let url: URL

    public init?(url: URL, width: Int = 320, height: Int = 180, softwareDecoding: Bool = false) {
        self.url = url
        #if canImport(VLCKit)
        self.width = width; self.height = height
        _ = softwareDecoding   // the grab always decodes in software: hardware surfaces arrive blank through the memory output
        guard reel_thumb_available() else { return nil }
        #else
        return nil
        #endif
    }

    /// A player of its own for each run. Restarting or seeking a player on an AVI whose index lies
    /// about keyframes gives frozen or garbage pictures; a fresh input from a fresh player, started
    /// before the wanted time, is the one way that has proved clean.
    private func openSession() -> Bool {
        #if canImport(VLCKit)
        closeSession()
        let options = [":no-audio", ":network-caching=1500", ":no-spu", ":no-osd", ":avcodec-hw=none", ":no-videotoolbox"]
        let cOptions = options.map { strdup($0) }
        defer { cOptions.forEach { free($0) } }
        let me = Unmanaged.passRetained(self)
        let handle = cOptions.map { UnsafePointer($0) }.withUnsafeBufferPointer { ptr in
            reel_grab_open(VLCLibrary.shared().instance, url.absoluteString, ptr.baseAddress, Int32(options.count), UInt32(width), UInt32(height), { context, pixels, w, h, stride, time in
                guard let context, let pixels else { return }
                let grabber = Unmanaged<FrameGrabber>.fromOpaque(context).takeUnretainedValue()
                grabber.deliver(pixels: pixels, width: Int(w), height: Int(h), stride: Int(stride), time: TimeInterval(time) / 1000)
            }, me.toOpaque())
        }
        guard let handle else { me.release(); return false }
        lock.lock(); session = handle; unmanaged = me; lock.unlock()
        return true
        #else
        return false
        #endif
    }

    private func closeSession() {
        lock.lock()
        let s = session; session = nil; onFrame = nil
        let u = unmanaged; unmanaged = nil
        lock.unlock()
        guard let s else { return }
        reel_grab_close(s)
        u?.release()
    }

    private func deliver(pixels: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, time: TimeInterval) {
        lock.lock(); let handler = onFrame; lock.unlock()
        guard let handler, let image = Self.image(rgba: pixels, width: width, height: height, stride: stride) else { return }
        handler(image, time)
    }

    /// How far before a wanted time playback starts. Seeking into an AVI lands on whatever its index
    /// calls a keyframe, which is not always one: the decoder then gives a garbage frame and a frozen
    /// picture until the next real keyframe, up to ten seconds on. Every grab therefore starts a
    /// fresh input this far back and discards the run-up, leaving only clean frames.
    public static let leadIn: TimeInterval = 20   // XviD puts keyframes up to 12.5 s apart (300 frames at 23.976 fps)

    /// VLC's output while the decoder has nothing yet (after a seek, until the next keyframe): a
    /// uniform mid-grey. Not a picture from the file, so never kept.
    static func isPlaceholder(_ image: CGImage) -> Bool {
        guard let p = FrameFingerprint(image), let lo = p.luma.min(), let hi = p.luma.max() else { return false }
        return hi - lo < 8 && p.brightness > 118 && p.brightness < 138
    }

    /// Frames from `from`, one every `spacing` seconds, `count` of them, playing at `rate`, from a
    /// fresh start of the input. `each` sees every kept frame as it arrives and may return true to
    /// stop early. Returns what arrived once the run is covered, or when nothing more comes for a while.
    @discardableResult
    public func frames(from: TimeInterval, count: Int, spacing: TimeInterval, rate: Float = 8, each: (@Sendable (TimeInterval, CGImage) -> Bool)? = nil) async -> [(time: TimeInterval, image: CGImage)] {
        // The previous run's player is torn down off the main thread (libvlc blocks for it).
        let opened: Bool = await Task.detached(priority: .utility) { [self] in openSession() }.value
        guard opened, let session = lock.withLock({ session }) else { return [] }
        let targets = (0..<count).map { from + TimeInterval($0) * spacing }
        let end = targets.last ?? from
        let begin = max(0, from - Self.leadIn)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[(TimeInterval, CGImage)], Never>) in
            let state = RunState(continuation: continuation)
            lock.lock()
            onFrame = { [weak self] image, time in
                guard let self else { return }
                var stop = false
                state.lock.lock()
                guard !state.done else { state.lock.unlock(); return }
                state.lastFrameAt = Date()
                state.delivered += 1
                if state.delivered <= 3 || state.delivered % 50 == 0 { state.seen.append(time) }
                // The start-time request is sometimes dropped and playback begins at 0: seek once.
                if !state.sought, time < begin - 1.5 { state.sought = true; state.lock.unlock(); if let s = self.lock.withLock({ self.session }) { _ = reel_grab_seek(s, Int64(begin * 1000), true) }; return }
                if Self.isPlaceholder(image) { state.placeholders += 1; state.lock.unlock(); return }
                // The first frame at or past each target; the run-up before the first is skipped. A
                // frame that covers two targets is kept for both, so every slot has a print.
                while state.next < targets.count, time >= targets[state.next] - 0.05 {
                    state.collected.append((targets[state.next], image))
                    state.next += 1
                    if let each, each(targets[state.next - 1], image) { stop = true; break }
                }
                if stop || state.next >= targets.count || time >= end + spacing { state.finish() }
                state.lock.unlock()
                if stop || state.next >= targets.count || time >= end + spacing { self.clearHandler() }
            }
            lock.unlock()
            if reel_grab_play(session, Int64(begin * 1000), rate) != 0 { state.lock.withLock { state.finish() }; clearHandler(); return }
            // Give up when frames stop arriving (a stream that will not open, a stuck decoder).
            Task.detached { [weak self] in
                let budget = max(20, (end - begin) / TimeInterval(max(rate, 1)) + 20)
                let started = Date()
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    let outcome: Int = state.lock.withLock {
                        if state.done { return 0 }
                        let stale = Date().timeIntervalSince(state.lastFrameAt ?? started) > 15 || Date().timeIntervalSince(started) > budget
                        if stale {
                            Self.log?("grab from \(Int(begin))s gave up after \(Int(Date().timeIntervalSince(started)))s: \(state.delivered) frames delivered (\(state.placeholders) placeholders), \(state.collected.count) kept, times seen \(state.seen.map { Int($0) })")
                            state.finish(); return 1
                        }
                        return 2
                    }
                    if outcome == 0 { return }
                    if outcome == 1 { self?.clearHandler(); return }
                }
            }
        }
    }

    /// The first clean frame at or after `seconds`, with its time: a fresh start 12 s back, the
    /// run-up discarded. About two seconds over a share.
    public func frame(at seconds: TimeInterval) async -> (time: TimeInterval, image: CGImage)? {
        await frames(from: seconds, count: 1, spacing: 1).first
    }
    private func clearHandler() { lock.lock(); onFrame = nil; lock.unlock() }

    /// Stops and releases the stream. Blocks for libvlc's teardown; run it off the main thread.
    public func close() { closeSession() }
    deinit { closeSession() }

    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var collected: [(TimeInterval, CGImage)] = []
        var next = 0
        var done = false
        var lastFrameAt: Date?
        var delivered = 0
        var placeholders = 0
        var sought = false
        var seen: [TimeInterval] = []
        private var continuation: CheckedContinuation<[(TimeInterval, CGImage)], Never>?
        init(continuation: CheckedContinuation<[(TimeInterval, CGImage)], Never>) { self.continuation = continuation }
        /// Caller holds `lock`.
        func finish() { guard !done else { return }; done = true; let c = continuation; continuation = nil; c?.resume(returning: collected) }
    }

    static func image(rgba: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGImage? {
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        let data = Data(bytes: rgba, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
