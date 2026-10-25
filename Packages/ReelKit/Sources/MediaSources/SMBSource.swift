#if canImport(AMSMB2)
import Foundation
import MediaCore
import AMSMB2

/// SMB 2/3 via AMSMB2 for browsing and stat. Playback hands VLC an `smb://` URL so VLC does
/// its own buffered reads (PLAN.md §11.2).
public actor SMBSource: MediaSource {
    public let config: SourceConfig
    private var client: SMB2Manager?
    private var credentials: Credentials?

    public init(config: SourceConfig) { self.config = config }

    private var serverURL: URL {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = config.host
        c.port = config.port
        return c.url!
    }

    public func connect(credentials: Credentials?) async throws {
        self.credentials = credentials
        let cred: URLCredential? = credentials.map { URLCredential(user: $0.username, password: $0.password, persistence: .forSession) }
        guard let manager = SMB2Manager(url: serverURL, credential: cred) else { throw SourceError.unreachable(config.host) }
        // Two tries of 10 s: a NAS that has gone to sleep should read as unreachable in ~20 s, not 50.
        manager.timeout = 10
        let started = Date()
        do {
            try await withRetries(2) {
                do {
                    try await manager.connectShare(name: self.config.path)
                } catch let e as NSError {
                    Diagnostics.log("source", "smb \(self.config.host)/\(self.config.path): \(e.domain) \(e.code) \(e.localizedDescription)")
                // libsmb2 reports auth failures as EACCES/EPERM; everything else is treated as unreachable.
                if e.code == Int(EACCES) || e.code == Int(EPERM) || e.localizedDescription.localizedCaseInsensitiveContains("logon") {
                        throw SourceError.authFailed
                    }
                    throw SourceError.unreachable(self.config.host)
                }
            }
        } catch {
            Diagnostics.log("source", "smb \(config.host)/\(config.path) failed after \(Int(Date().timeIntervalSince(started)))s: \(error)")
            throw error
        }
        Diagnostics.log("source", "smb \(config.host)/\(config.path) connected in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        client = manager
    }

    public func list(_ relativePath: String) async throws -> [DirectoryEntry] {
        guard let client else { throw SourceError.unreachable(config.host) }
        let items = try await client.contentsOfDirectory(atPath: relativePath)
        return items.compactMap { attrs -> DirectoryEntry? in
            guard let name = attrs[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let isDir = (attrs[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let rel = relativePath.isEmpty ? name : relativePath + "/" + name
            return DirectoryEntry(name: name, relativePath: rel, isDirectory: isDir, size: (attrs[.fileSizeKey] as? NSNumber)?.int64Value, modified: attrs[.contentModificationDateKey] as? Date)
        }.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        guard let client else { throw SourceError.unreachable(config.host) }
        let attrs = try await client.attributesOfItem(atPath: relativePath)
        let isDir = (attrs[.fileResourceTypeKey] as? URLFileResourceType) == .directory
        return DirectoryEntry(name: (relativePath as NSString).lastPathComponent, relativePath: relativePath, isDirectory: isDir, size: (attrs[.fileSizeKey] as? NSNumber)?.int64Value, modified: attrs[.contentModificationDateKey] as? Date)
    }

    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = config.host
        c.port = config.port
        if let creds = credentials ?? self.credentials {
            c.user = creds.username
            c.password = creds.password
        }
        c.path = "/" + ([config.path] + relativePath.split(separator: "/").map(String.init)).joined(separator: "/")
        guard let url = c.url else { throw SourceError.notFound(relativePath) }
        return url
    }

    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        guard let client else { throw SourceError.unreachable(config.host) }
        try await client.downloadItem(atPath: relativePath, to: destination, progress: { bytes, total in progress(bytes, total) })
    }

    public func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        guard let client else { throw SourceError.unreachable(config.host) }
        let start = UInt64(max(0, offset))
        return try await client.contents(atPath: relativePath, range: start..<(start + UInt64(length)), progress: nil)
    }

    public func disconnect() async {
        try? await client?.disconnectShare()
        client = nil
    }
}
#endif
