import Foundation

/// What kind of thing a library item is.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case film
    case show
    case episode
}

/// How a folder was tagged by the user. Overrides filename heuristics.
public enum FolderTag: String, Codable, Sendable, CaseIterable {
    case tv
    case films
    case mixed
    case excluded
}

/// How confident the matcher was. Low-confidence matches get a badge in the UI.
public enum MatchConfidence: String, Codable, Sendable {
    case autoHigh
    case autoLow
    case manual
    case unmatched
}

/// Source protocol family. Drives which `MediaSource` implementation is used.
public enum SourceType: String, Codable, Sendable, CaseIterable, Identifiable {
    case local
    case smb
    case webdav
    case ftp
    case sftp
    case nfs
    case dlna

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .smb: "SMB"
        case .webdav: "WebDAV"
        case .ftp: "FTP"
        case .sftp: "SFTP"
        case .nfs: "NFS"
        case .dlna: "DLNA"
        }
    }

    /// Protocols that VLC can open directly by URL at playback time.
    public var vlcScheme: String? {
        switch self {
        case .local: "file"
        case .smb: "smb"
        case .webdav: nil // http/https chosen per source
        case .ftp: "ftp"
        case .sftp: "sftp"
        case .nfs: "nfs"
        case .dlna: nil // http URL from ContentDirectory
        }
    }
}

/// Connection state reported by a `MediaSource`.
public enum SourceStatus: String, Codable, Sendable {
    case unknown
    case online
    case offline
    case authFailed
    case scanning
}

/// A single entry returned when listing a directory on any source.
public struct DirectoryEntry: Hashable, Sendable {
    public var name: String
    public var relativePath: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?

    public init(name: String, relativePath: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var isVideo: Bool { VideoFile.videoExtensions.contains(fileExtension) }
    public var isSubtitle: Bool { VideoFile.subtitleExtensions.contains(fileExtension) }
}

/// Extension lists used by the scanner.
public enum VideoFile {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "wmv", "flv",
        "webm", "mpg", "mpeg", "vob", "3gp", "ogv", "divx", "asf", "rm", "rmvb", "iso",
    ]
    public static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "smi"]
}

/// A track of audio or subtitles as reported by the playback engine.
public struct MediaTrack: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var language: String?
    public var codec: String?
    public var channels: Int?
    public var isForced: Bool

    public init(id: Int, name: String, language: String? = nil, codec: String? = nil, channels: Int? = nil, isForced: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.codec = codec
        self.channels = channels
        self.isForced = isForced
    }
}

/// A chapter marker.
public struct Chapter: Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(id: Int, title: String, start: TimeInterval, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.start = start
        self.duration = duration
    }

    /// Heuristic: a chapter named like an intro/opening in the first 10 minutes.
    public var looksLikeIntro: Bool {
        let t = title.lowercased()
        return start < 600 && (t.contains("intro") || t.contains("opening") || t.contains("titles") || t.contains("op"))
    }
}
