import Foundation
import MediaCore

/// Persisted, credential-free description of a source. Credentials live in `CredentialStore`.
public struct SourceConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var type: SourceType
    public var host: String
    public var port: Int?
    /// SMB share name, WebDAV path, or local bookmark identifier.
    public var path: String
    public var useTLS: Bool
    public var username: String?
    /// Hardware address for Wake-on-LAN, so a NAS that has gone to sleep can be woken before playback.
    public var macAddress: String?

    public init(id: UUID = UUID(), name: String, type: SourceType, host: String = "", port: Int? = nil, path: String = "", useTLS: Bool = true, username: String? = nil, macAddress: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.path = path
        self.useTLS = useTLS
        self.username = username
        self.macAddress = macAddress
    }
}

public enum SourceError: Error, LocalizedError, Sendable {
    case unreachable(String)
    case authFailed
    case notFound(String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Can't reach \(host). Check the address and that you're on the same network."
        case .authFailed: "Password rejected. The host answered but refused the login."
        case .notFound(let p): "\(p) was not found. It may have been moved."
        case .unsupported(let what): "\(what) isn't supported yet."
        case .cancelled: "Cancelled."
        }
    }
}

/// Everything the scanner and the player need from a source. One actor per source keeps
/// connection state in one place and serialises reconnects.
public protocol MediaSource: Actor {
    nonisolated var config: SourceConfig { get }

    /// Opens a session. Throws `SourceError.authFailed` or `.unreachable`.
    func connect(credentials: Credentials?) async throws

    /// Lists one directory. `relativePath` is "" for the root.
    func list(_ relativePath: String) async throws -> [DirectoryEntry]

    /// Size and modified date for one path.
    func stat(_ relativePath: String) async throws -> DirectoryEntry

    /// A URL VLC can open directly. Credentials may be embedded; never persist this value.
    func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL

    /// Copies a file to `destination` for offline playback. `progress` gets (bytes so far, total)
    /// and returns false to abort. Requires `connect` first.
    func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws

    /// `length` bytes from `offset` of a file, for the local HTTP bridge that lets Apple's player
    /// (and so AirPlay video) read a file on a share. Requires `connect` first. May return fewer
    /// bytes at the end of the file.
    func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data

    /// False for a source that cannot serve `read`, so the AirPlay bridge is not offered a file it
    /// could never send; those files go to Apple's player through VLC's HLS copy instead.
    nonisolated var supportsRangedReads: Bool { get }

    func disconnect() async
}

public extension MediaSource {
    func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        throw SourceError.unsupported("ranged reads on \(config.type.rawValue)")
    }
    nonisolated var supportsRangedReads: Bool { true }
}

public struct Credentials: Sendable, Hashable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}

public enum SourceFactory {
    /// Builds SFTP and NFS sources, which VLC's own access modules back (the Playback module
    /// registers it at launch; this module cannot depend on VLCKit).
    public static var vlcBackedMaker: (@Sendable (SourceConfig) -> any MediaSource)?
    /// Development only: route FTP through the VLC-backed source too, to exercise that path against
    /// an FTP server (VLC's ftp, sftp and nfs modules share the directory-listing code).
    public static var preferVLCForFTP = false

    /// Builds the right implementation for a config.
    public static func make(_ config: SourceConfig) -> any MediaSource {
        switch config.type {
        case .local: return LocalSource(config: config)
        case .webdav: return WebDAVSource(config: config)
        case .smb:
            #if canImport(AMSMB2)
            return SMBSource(config: config)
            #else
            return UnsupportedSource(config: config)
            #endif
        case .ftp:
            if preferVLCForFTP, let maker = vlcBackedMaker { return maker(config) }
            #if canImport(Network)
            return FTPSource(config: config)
            #else
            return UnsupportedSource(config: config)
            #endif
        case .dlna:
            #if canImport(Network)
            return DLNASource(config: config)
            #else
            return UnsupportedSource(config: config)
            #endif
        case .sftp, .nfs: return vlcBackedMaker?(config) ?? UnsupportedSource(config: config)
        }
    }
}

/// Stands in for a source type whose implementation is not available in this build.
public actor UnsupportedSource: MediaSource {
    public let config: SourceConfig
    public init(config: SourceConfig) { self.config = config }
    public func connect(credentials: Credentials?) async throws { throw SourceError.unsupported(config.type.displayName) }
    public func list(_ relativePath: String) async throws -> [DirectoryEntry] { throw SourceError.unsupported(config.type.displayName) }
    public func stat(_ relativePath: String) async throws -> DirectoryEntry { throw SourceError.unsupported(config.type.displayName) }
    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL { throw SourceError.unsupported(config.type.displayName) }
    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws { throw SourceError.unsupported(config.type.displayName) }
    public func disconnect() async {}
}

/// Exponential backoff shared by the network sources: 1 s, 2 s, 4 s, then give up.
func withRetries<T>(_ attempts: Int = 3, _ body: () async throws -> T) async throws -> T {
    var delay: UInt64 = 1_000_000_000
    for attempt in 0..<attempts {
        do { return try await body() }
        catch SourceError.authFailed { throw SourceError.authFailed }
        catch {
            if attempt == attempts - 1 { throw error }
            try await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
    }
    throw SourceError.cancelled
}
