import Foundation
import CoreGraphics
import ReelVLCThumb
#if canImport(VLCKit)
import VLCKit
#endif

/// One frame at an exact time, through libvlc's thumbnailer with a precise seek (decoding from the
/// keyframe before up to the frame asked for). VLCKit's VLCMediaThumbnailer seeks fast and hands
/// back that keyframe instead, which on an AVI can be a dozen seconds early; fingerprints taken that
/// way repeat the same picture for seconds on end and never line up with another episode's.
public enum PreciseThumbnail {
    public static var isAvailable: Bool { reel_thumb_available() }

    /// The frame at `seconds`, or nil when it could not be made within the timeout.
    public static func frame(url: URL, at seconds: TimeInterval, width: Int = 320, height: Int = 180, softwareDecoding: Bool = false, timeout: TimeInterval = 20) async -> CGImage? {
        #if canImport(VLCKit)
        let instance = VLCLibrary.shared().instance
        var options = [":no-audio", ":network-caching=500"]
        if softwareDecoding { options.append(":avcodec-hw=none") }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let box = Box(continuation)
            let unmanaged = Unmanaged.passRetained(box)
            let cOptions = options.map { strdup($0) }
            defer { cOptions.forEach { free($0) } }
            let handle = cOptions.map { UnsafePointer($0) }.withUnsafeBufferPointer { ptr in
                reel_thumb_request(instance, url.absoluteString, ptr.baseAddress, Int32(options.count), Int64(seconds * 1000), UInt32(width), UInt32(height), Int64(timeout * 1000), { context, pixels, w, h, stride, _ in
                    guard let context else { return }
                    let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                    box.finish(pixels.flatMap { Self.image(rgba: $0, width: Int(w), height: Int(h), stride: Int(stride)) })
                }, unmanaged.toOpaque())
            }
            guard let handle else { unmanaged.release(); box.finish(nil); return }
            box.handle = handle
            // The request is released on a queue of its own after the callback: destroying it from
            // inside the callback would wait on the thread that is delivering it.
            box.onFinish = { reel_thumb_finish(handle); unmanaged.release() }
        }
        #else
        return nil
        #endif
    }

    private final class Box: @unchecked Sendable {
        private var continuation: CheckedContinuation<CGImage?, Never>?
        var handle: UnsafeMutableRawPointer?
        var onFinish: (() -> Void)?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<CGImage?, Never>) { continuation = c }
        func finish(_ image: CGImage?) {
            lock.lock()
            let c = continuation; continuation = nil
            let done = onFinish; onFinish = nil
            lock.unlock()
            c?.resume(returning: image)
            if let done { DispatchQueue.global(qos: .utility).async(execute: done) }
        }
    }

    private static func image(rgba: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGImage? {
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        let data = Data(bytes: rgba, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
