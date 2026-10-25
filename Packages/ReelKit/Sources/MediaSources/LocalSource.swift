import Foundation
import MediaCore

/// Folders picked with the Files document picker. We hold a security-scoped bookmark and
/// read in place; nothing is copied into the app container.
public actor LocalSource: MediaSource {
    public let config: SourceConfig
    private var root: URL?
    private var accessing = false

    public init(config: SourceConfig) { self.config = config }

    /// Stores a bookmark for a folder URL the user just picked. Call before `connect`.
    public static func bookmarkData(for url: URL) throws -> Data {
        #if os(iOS)
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// `path` prefix for a folder shipped inside the app bundle (the sample library): "bundle:Demo".
    public static let bundlePrefix = "bundle:"

    public func connect(credentials: Credentials?) async throws {
        if config.path.hasPrefix(Self.bundlePrefix) {
            let sub = String(config.path.dropFirst(Self.bundlePrefix.count))
            guard let base = Bundle.main.resourceURL?.appendingPathComponent(sub, isDirectory: true),
                  FileManager.default.fileExists(atPath: base.path) else { throw SourceError.notFound(config.name) }
            root = base
            return
        }
        guard let data = Data(base64Encoded: config.path) else { throw SourceError.notFound(config.name) }
        var stale = false
        #if os(iOS)
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard url.startAccessingSecurityScopedResource() else { throw SourceError.unreachable(config.name) }
        accessing = true
        root = url
    }

    public func list(_ relativePath: String) async throws -> [DirectoryEntry] {
        let dir = try resolve(relativePath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let rel = relativePath.isEmpty ? url.lastPathComponent : relativePath + "/" + url.lastPathComponent
            return DirectoryEntry(name: url.lastPathComponent, relativePath: rel, isDirectory: v.isDirectory ?? false, size: v.fileSize.map(Int64.init), modified: v.contentModificationDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        let url = try resolve(relativePath)
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return DirectoryEntry(name: url.lastPathComponent, relativePath: relativePath, isDirectory: v.isDirectory ?? false, size: v.fileSize.map(Int64.init), modified: v.contentModificationDate)
    }

    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL {
        try resolve(relativePath)
    }

    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        let from = try resolve(relativePath)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: from, to: destination)
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        _ = progress(size, size)
    }

    public func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        let url = try resolve(relativePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return try handle.read(upToCount: length) ?? Data()
    }

    public func disconnect() async {
        if accessing { root?.stopAccessingSecurityScopedResource() }
        accessing = false
        root = nil
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard let root else { throw SourceError.unreachable(config.name) }
        return relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
    }
}
