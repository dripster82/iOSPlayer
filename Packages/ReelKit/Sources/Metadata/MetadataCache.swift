import Foundation

/// Disk cache for raw TMDb responses, keyed by request URL. Metadata expires after 7 days;
/// a stale entry is still returned when the network is down so the library keeps working offline.
public actor MetadataCache {
    public static let defaultTTL: TimeInterval = 7 * 24 * 3600

    private let directory: URL
    private let ttl: TimeInterval
    private let fm = FileManager.default

    public init(directory: URL? = nil, ttl: TimeInterval = MetadataCache.defaultTTL) {
        let base = directory ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("metadata", isDirectory: true)
        self.directory = base
        self.ttl = ttl
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public struct Entry: Sendable { public var data: Data; public var isFresh: Bool }

    public func read(_ key: String) -> Entry? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Entry(data: data, isFresh: Date().timeIntervalSince(modified) < ttl)
    }

    public func write(_ key: String, data: Data) {
        try? data.write(to: fileURL(key), options: .atomic)
    }

    public func removeAll() {
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func sizeOnDisk() -> Int64 {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func fileURL(_ key: String) -> URL {
        var h = FNV1a64()
        h.update(key)
        return directory.appendingPathComponent(h.hex + ".json")
    }
}

struct FNV1a64 {
    private var hash: UInt64 = 0xcbf29ce484222325
    mutating func update(_ s: String) { for b in s.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001b3 } }
    var hex: String { String(hash, radix: 16) }
}
