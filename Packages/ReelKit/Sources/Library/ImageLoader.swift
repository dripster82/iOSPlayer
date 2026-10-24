#if canImport(UIKit)
import Foundation
import UIKit

/// Memory + disk cache for artwork. PLAN.md §11.5: 2 GB default limit, LRU eviction by access date.
public actor ImageLoader {
    public static let shared = ImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    public var diskLimitBytes: Int64 {
        get { Int64(UserDefaults.standard.object(forKey: "reel.artworkLimit") as? Int ?? 2_000_000_000) }
    }

    public init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 150 * 1024 * 1024
    }

    public func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        if let task = inflight[url] { return await task.value }
        let task = Task<UIImage?, Never> { [directory] in
            let file = directory.appendingPathComponent(Self.key(url))
            // `preparingForDisplay` decodes now, on this background task, instead of lazily on the main thread at draw time.
            if let data = try? Data(contentsOf: file), let img = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return img
            }
            guard let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let img = UIImage(data: result.0)?.preparingForDisplay() ?? UIImage(data: result.0) else { return nil }
            try? result.0.write(to: file, options: .atomic)
            return img
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { memory.setObject(result, forKey: url as NSURL, cost: Int(result.size.width * result.size.height * 4)) }
        return result
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
