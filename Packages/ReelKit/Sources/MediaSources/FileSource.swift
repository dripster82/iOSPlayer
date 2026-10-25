import Foundation
import MediaCore

/// One local file as a source, for the stream bridge: a remuxed copy in Caches, or a download.
public actor FileSource: MediaSource {
    nonisolated public let config: SourceConfig
    private let url: URL
    public init(url: URL) {
        self.url = url
        config = SourceConfig(name: url.lastPathComponent, type: .local, path: url.path)
    }
    public func connect(credentials: Credentials?) async throws {}
    public func list(_ relativePath: String) async throws -> [DirectoryEntry] { [] }
    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return DirectoryEntry(name: url.lastPathComponent, relativePath: relativePath, isDirectory: false, size: size, modified: nil)
    }
    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL { url }
    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        try FileManager.default.copyItem(at: url, to: destination)
    }
    public func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return try handle.read(upToCount: length) ?? Data()
    }
    public func disconnect() async {}
}
