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

    private var session: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var onFrame: ((CGImage, TimeInterval) -> Void)?
    private let width: Int, height: Int
    private var unmanaged: Unmanaged<FrameGrabber>?

    /// Opens the file; nil when libvlc is not available or the stream cannot be set up.
    public init?(url: URL, width: Int = 320, height: Int = 180, softwareDecoding: Bool = false) {
        #if canImport(VLCKit)
        self.width = width; self.height = height
        var options = [":no-audio", ":network-caching=1500", ":no-spu", ":no-osd"]
        if softwareDecoding { options.append(":avcodec-hw=none") }
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
        guard let handle else { me.release(); return nil }
        session = handle
        unmanaged = me
        #else
        return nil
        #endif
    }

    private func deliver(pixels: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, time: TimeInterval) {
        lock.lock(); let handler = onFrame; lock.unlock()
        guard let handler, let image = Self.image(rgba: pixels, width: width, height: height, stride: stride) else { return }
        handler(image, time)
    }

    /// Frames from `from`, one every `spacing` seconds, `count` of them, playing at `rate`. Returns
    /// what arrived (in order) once the run is covered, or when nothing more comes for a while.
    public func frames(from: TimeInterval, count: Int, spacing: TimeInterval, rate: Float = 8) async -> [(time: TimeInterval, image: CGImage)] {
        guard let session else { return [] }
        let targets = (0..<count).map { from + TimeInterval($0) * spacing }
        let end = targets.last ?? from
        return await withCheckedContinuation { (continuation: CheckedContinuation<[(TimeInterval, CGImage)], Never>) in
            let state = RunState(continuation: continuation)
            lock.lock()
            onFrame = { [weak self] image, time in
                guard let self else { return }
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.done else { return }
                state.lastFrameAt = Date()
                // The first frame at or past each target; frames before the first target are skipped.
                while state.next < targets.count, time >= targets[state.next] - 0.05 {
                    if state.collected.last?.1 !== image { state.collected.append((targets[state.next], image)) }
                    state.next += 1
                }
                if state.next >= targets.count || time >= end + spacing { state.finish(); self.clearHandler() }
            }
            lock.unlock()
            playing = true
            if reel_grab_play(session, Int64(from * 1000), rate) != 0 { state.lock.withLock { state.finish() }; clearHandler(); return }
            // Give up when frames stop arriving (a stream that will not open, a stuck decoder).
            Task.detached { [weak self] in
                let budget = max(20, (end - from) / TimeInterval(max(rate, 1)) + 20)
                let started = Date()
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    let outcome: Int = state.lock.withLock {
                        if state.done { return 0 }
                        let stale = Date().timeIntervalSince(state.lastFrameAt ?? started) > 15 || Date().timeIntervalSince(started) > budget
                        if stale { state.finish(); return 1 }
                        return 2
                    }
                    if outcome == 0 { return }
                    if outcome == 1 { self?.clearHandler(); return }
                }
            }
        }
    }

    /// Seeks precisely to `seconds` and returns the next frame that arrives from there, or nil
    /// after a timeout. The session must be playing (`frames` or a prior `frame`).
    public func frame(at seconds: TimeInterval, timeout: TimeInterval = 15) async -> CGImage? {
        guard let session else { return nil }
        if !playing { if reel_grab_play(session, Int64(seconds * 1000), 1) != 0 { return nil }; playing = true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let one = OneState(continuation: continuation)
            lock.lock()
            onFrame = { [weak self] image, time in
                // A frame from before the seek landed (the old position) is not the one.
                guard time >= seconds - 1.5, time <= seconds + 4 else { return }
                let first: Bool = one.lock.withLock { let f = !one.done; one.done = true; return f }
                if first { continuation.resume(returning: image); self?.clearHandler() }
            }
            lock.unlock()
            _ = reel_grab_seek(session, Int64(seconds * 1000))
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                let first: Bool = one.lock.withLock { let f = !one.done; one.done = true; return f }
                if first { continuation.resume(returning: nil); self?.clearHandler() }
            }
        }
    }
    private var playing = false

    private func clearHandler() { lock.lock(); onFrame = nil; lock.unlock() }

    /// Stops and releases the stream. Blocks for libvlc's teardown; run it off the main thread.
    public func close() {
        lock.lock()
        let s = session; session = nil; onFrame = nil
        lock.unlock()
        guard let s else { return }
        reel_grab_close(s)
        unmanaged?.release(); unmanaged = nil
    }
    deinit { if session != nil { close() } }

    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var collected: [(TimeInterval, CGImage)] = []
        var next = 0
        var done = false
        var lastFrameAt: Date?
        private var continuation: CheckedContinuation<[(TimeInterval, CGImage)], Never>?
        init(continuation: CheckedContinuation<[(TimeInterval, CGImage)], Never>) { self.continuation = continuation }
        /// Caller holds `lock`.
        func finish() { guard !done else { return }; done = true; let c = continuation; continuation = nil; c?.resume(returning: collected) }
    }
    private final class OneState: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        let continuation: CheckedContinuation<CGImage?, Never>
        init(continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
    }

    static func image(rgba: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGImage? {
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        let data = Data(bytes: rgba, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
