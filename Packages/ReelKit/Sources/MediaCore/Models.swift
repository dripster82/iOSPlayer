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
    /// Housekeeping folders a NAS shows but nobody films in: dotfiles, Synology's `@eaDir`, `#recycle`
    /// and `#snapshot`, QNAP's `.@__thumb`. Never offered as a library folder, never walked.
    public static func isSystemFolder(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("@") || name.hasPrefix("#") || name.lowercased() == "$recycle.bin" || name.lowercased() == "system volume information"
    }
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

    /// A chapter named like an intro or opening, in the first 10 minutes. Whole words only: "op" must
    /// not match "Shop" or "Opening Credits" by accident, and "intro" must not match "Introduction of
    /// the Suspects". Generic names ("Chapter 2", "Track 3") say nothing and never match.
    public var looksLikeIntro: Bool {
        guard start < 600 else { return false }
        return Self.introWords.contains { Self.words(in: title).contains($0) }
    }

    /// Names the tools write for the opening; "op"/"ed" are the anime convention (opening/ending).
    static let introWords: Set<String> = ["intro", "opening", "titles", "op", "theme", "credits", "recap", "cold open"]

    /// A chapter named like the end credits, in the last 15 minutes: "Credits", "End Credits",
    /// "Closing Credits", "Outro", "Ending", the anime "ED". "Opening Credits" early in the file is
    /// the intro's business, which `start >= end - 900` keeps out.
    public func looksLikeCredits(fileDuration: TimeInterval) -> Bool {
        guard fileDuration > 0, start >= fileDuration - 900 else { return false }
        let words = Self.words(in: title)
        return Self.creditsWords.contains { words.contains($0) }
    }
    static let creditsWords: Set<String> = ["credits", "end credits", "closing credits", "outro", "ending", "ed", "end titles"]

    static func words(in title: String) -> Set<String> {
        let lower = title.lowercased()
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var set = Set(tokens)
        for i in tokens.indices.dropLast() { set.insert(tokens[i] + " " + tokens[i + 1]) }   // "cold open"
        return set
    }

    /// True for the automatic "Chapter 1", "Track 2", "Kapitel 3" names tools write when nobody named
    /// the chapters; those carry no information about what the chapter is.
    public var hasGenericTitle: Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        let generic = ["chapter", "track", "kapitel", "capítulo", "chapitre", "part"]
        return generic.contains { prefix in
            t.hasPrefix(prefix) && t.dropFirst(prefix.count).allSatisfy { $0 == " " || $0.isNumber }
        } || t.allSatisfy(\.isNumber) || t.isEmpty
    }
}

public extension Array where Element == Chapter {
    /// The chapter the Skip intro button should jump over, or nil.
    ///
    /// Named chapters win. Unnamed ones fall back to shape: TV episodes are usually cut as a cold
    /// open, the title sequence, then the story. Title sequences run 25–95 s; cold opens run longer
    /// (Stargate Atlantis S01E15: a 118 s cold open, then the 61 s titles). Among chapters that start
    /// in the first five minutes and are not the last, a title-length chapter that follows another
    /// chapter is preferred over the first chapter; the first is used only when nothing else fits.
    /// Only when every chapter is unnamed; films with a handful of long chapters match nothing.
    /// Where the end credits begin, by chapters, or nil. A named credits chapter wins; failing that,
    /// among unnamed chapters only, a short final chapter (under four minutes, in the last tenth of the
    /// file) is taken as the credits, since that is how most TV rips are cut. Films with a handful of
    /// long chapters match nothing, and so does a last chapter that is a whole scene.
    public func creditsStart(fileDuration: TimeInterval) -> TimeInterval? {
        if let named = first(where: { $0.looksLikeCredits(fileDuration: fileDuration) }) { return named.start }
        guard fileDuration > 0, count >= 3, allSatisfy(\.hasGenericTitle), let last = self.last else { return nil }
        let endsAtFileEnd = fileDuration - (last.start + last.duration) < 15
        guard endsAtFileEnd, last.duration >= 15, last.duration <= 240, last.start >= fileDuration * 0.9 else { return nil }
        return last.start
    }

    var intro: Chapter? {
        if let named = first(where: \.looksLikeIntro) { return named }
        guard count >= 3, allSatisfy(\.hasGenericTitle) else { return nil }
        let early = dropLast().filter { $0.start < 300 }
        let titleLength = early.filter { $0.duration >= 25 && $0.duration <= 95 }
        if let afterColdOpen = titleLength.first(where: { $0.id != early.first?.id }) { return afterColdOpen }
        if let first = titleLength.first { return first }
        return early.first { $0.duration >= 20 && $0.duration <= 120 && $0.id != early.first?.id }
    }
}
