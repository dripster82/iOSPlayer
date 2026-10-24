#if canImport(UIKit)
import Foundation
import UIKit
import ImageIO

/// Memory + disk cache for artwork. PLAN.md §11.5: 2 GB default limit, LRU eviction by access date.
///
/// Decoding is sized to the view: a grid cell 120 pt wide asks for a 360 px decode and gets a
/// thumbnail made by ImageIO straight from the encoded bytes, not a 500×750 (or 2000×3000 for a
/// backdrop) bitmap scaled down at draw time. The downsampled bitmaps are what sits in memory,
/// keyed by URL and size bucket, so a grid of 200 posters costs a few megabytes instead of a few hundred.
public actor ImageLoader {
    public static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    public var diskLimitBytes: Int64 {
        get { Int64(UserDefaults.standard.object(forKey: "reel.artworkLimit") as? Int ?? 2_000_000_000) }
    }

    public init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    /// Full-size decode. Prefer `image(for:maxPixel:)` wherever the displayed size is known.
    public func image(for url: URL) async -> UIImage? { await image(for: url, maxPixel: nil) }

    /// `maxPixel` is the longest side the caller will draw, in pixels (points × screen scale). It is
    /// rounded up to a 128 px bucket so a cell that is 118 or 126 pt wide shares one decode.
    public func image(for url: URL, maxPixel: Int?) async -> UIImage? {
        let bucket = maxPixel.map { Self.bucket($0) }
        let memoryKey = Self.key(url) + (bucket.map { "@\($0)" } ?? "") as NSString
        if let cached = memory.object(forKey: memoryKey) { return cached }
        if let task = inflight[memoryKey as String] { return await task.value }
        let task = Task<UIImage?, Never> { [directory] in
            let file = directory.appendingPathComponent(Self.key(url))
            if let data = try? Data(contentsOf: file), let img = Self.decode(data, maxPixel: bucket) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return img
            }
            guard let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let img = Self.decode(result.0, maxPixel: bucket) else { return nil }
            try? result.0.write(to: file, options: .atomic)
            return img
        }
        inflight[memoryKey as String] = task
        let result = await task.value
        inflight[memoryKey as String] = nil
        if let result {
            let px = result.size.width * result.scale * result.size.height * result.scale
            memory.setObject(result, forKey: memoryKey, cost: Int(px * 4))
        }
        return result
    }

    public static func bucket(_ px: Int) -> Int { max(128, (px + 127) / 128 * 128) }

    /// ImageIO's thumbnail path decodes only what is needed for `maxPixel`; the full decode is kept
    /// for callers that did not say (and for the odd format ImageIO declines).
    nonisolated static func decode(_ data: Data, maxPixel: Int?) -> UIImage? {
        if let maxPixel, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return UIImage(cgImage: cg) }
        }
        // `preparingForDisplay` decodes now, on this background task, instead of lazily on the main thread at draw time.
        return UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data)
    }

    public func sizeOnDisk() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    public func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Evict least-recently-used files until under the limit. Call on launch and after scans.
    public func enforceLimit() {
        var all = files().sorted { $0.modified < $1.modified }
        var total = all.reduce(0) { $0 + $1.size }
        while total > diskLimitBytes, let oldest = all.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
    }

    private struct Entry { var url: URL; var size: Int64; var modified: Date }
    private func files() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: u, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
    }

    private static func key(_ url: URL) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in url.absoluteString.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16) + "." + (url.pathExtension.isEmpty ? "img" : url.pathExtension)
    }
}
#endif
