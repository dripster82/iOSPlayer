#if canImport(SwiftData)
import Foundation
import SwiftData
import MediaCore
import MediaSources

// SwiftData schema. Mirrors PLAN.md §11.6. Credentials are never stored here.

@Model
public final class SourceRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var typeRaw: String
    public var host: String
    public var port: Int?
    public var path: String
    public var useTLS: Bool
    public var username: String?
    public var statusRaw: String
    public var lastScan: Date?
    public var hiddenFromLibrary: Bool
    /// Sync bookkeeping (PLAN §10): the definition syncs, the password goes through iCloud Keychain.
    public var pendingSync: Bool = false
    public var updatedAt: Date? = nil
    /// Wake-on-LAN address; optional, synced with the rest of the definition.
    public var macAddress: String? = nil
    @Relationship(deleteRule: .cascade, inverse: \FolderRule.source) public var folderRules: [FolderRule]
    @Relationship(deleteRule: .cascade, inverse: \MediaFile.source) public var files: [MediaFile]

    public init(config: SourceConfig) {
        id = config.id
        name = config.name
        typeRaw = config.type.rawValue
        host = config.host
        port = config.port
        path = config.path
        useTLS = config.useTLS
        username = config.username
        macAddress = config.macAddress
        statusRaw = SourceStatus.unknown.rawValue
        hiddenFromLibrary = false
        folderRules = []
        files = []
    }

    public var type: SourceType { SourceType(rawValue: typeRaw) ?? .local }
    public var status: SourceStatus {
        get { SourceStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }
    public var config: SourceConfig {
        SourceConfig(id: id, name: name, type: type, host: host, port: port, path: path, useTLS: useTLS, username: username, macAddress: macAddress)
    }

    /// The most specific rule whose folder contains the path.
    public func tag(for relativePath: String) -> FolderTag? {
        let lower = relativePath.lowercased()
        return folderRules
            .filter { lower == $0.folderPath.lowercased() || lower.hasPrefix($0.folderPath.lowercased() + "/") }
            .max { $0.folderPath.count < $1.folderPath.count }?
            .tag
    }
}

@Model
public final class FolderRule {
    public var folderPath: String
    public var tagRaw: String
    public var includeInScan: Bool
    public var source: SourceRecord?

    public init(folderPath: String, tag: FolderTag, includeInScan: Bool = true) {
        self.folderPath = folderPath
        self.tagRaw = tag.rawValue
        self.includeInScan = includeInScan
    }
    public var tag: FolderTag { FolderTag(rawValue: tagRaw) ?? .mixed }
}

@Model
public final class MediaFile {
    @Attribute(.unique) public var id: UUID
    public var relativePath: String
    public var size: Int64
    public var modified: Date?
    public var duration: TimeInterval?
    public var videoCodec: String?
    public var resolution: String?
    public var audioSummary: String?
    public var subtitleSummary: String?
    /// Sidecar subtitle paths relative to the source root.
    public var sidecars: [String]
    public var qualityTags: [String]
    public var classificationRaw: String
    public var guessTitle: String?
    public var guessYear: Int?
    public var guessSeason: Int?
    public var guessEpisode: Int?
    /// "film" / "episode": the classifier's best guess for a review file, so the matcher can still try it.
    public var guessKindRaw: String?
    /// Sync bookkeeping. `syncKey` is the CloudKit record name (a hash of source id + path, since record
    /// names are capped at 255 characters); `itemKeyHint` links the file to its item once that item arrives.
    public var pendingSync: Bool = false
    public var updatedAt: Date? = nil
    public var syncKey: String? = nil
    public var itemKeyHint: String? = nil
    public var reviewed: Bool
    public var ignored: Bool
    public var addedAt: Date
    public var lastSeenAt: Date
    /// What a second database (Wikidata, TVmaze, Kitsu) thinks this file is, when it differs from or
    /// adds to TMDb's weak answer: shown first in Needs Review. Local to this device.
    public var suggestedTMDbID: Int? = nil
    public var suggestionSource: String? = nil
    /// Chapter starts (seconds) and titles, recorded the first time the file plays through VLC, so
    /// Apple's player (AirPlay) can offer the same chapter list.
    public var chapterStarts: [Double] = []
    public var chapterTitles: [String] = []
    /// Audio tracks as VLC lists them (name and language), recorded on play, so the AirPlay copy can
    /// offer the same choice.
    public var audioTrackNames: [String] = []
    public var audioTrackLanguages: [String] = []
    public var source: SourceRecord?
    public var item: MediaItem?

    public init(relativePath: String, size: Int64, modified: Date?, source: SourceRecord) {
        id = UUID()
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.source = source
        sidecars = []
        qualityTags = []
        classificationRaw = "pending"
        reviewed = false
        ignored = false
        addedAt = Date()
        lastSeenAt = Date()
    }

    public var fileName: String { (relativePath as NSString).lastPathComponent }
    /// Waiting in Needs Review: the matcher could not place it and the viewer has not decided, or
    /// decided and the decision still left it with no real match (the file keeps `reviewed` from
    /// that decision, and from the other device by sync, but a placeholder is not an answer).
    public var needsReview: Bool { classificationRaw == "review" && !ignored && (!reviewed || item == nil || item?.confidence == .unmatched) }
}

@Model
public final class MediaItem {
    /// Stable sync identity (PLAN.md §10.4). Unique per library.
    @Attribute(.unique) public var itemKey: String
    public var kindRaw: String
    public var tmdbID: Int?
    public var title: String
    public var sortTitle: String
    public var year: Int?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var stillPath: String?
    public var rating: Double?
    public var runtimeMinutes: Int?
    public var genres: [String]
    public var cast: [String]
    public var confidenceRaw: String
    public var addedAt: Date
    public var hidden: Bool
    /// Sync bookkeeping. `showKeyHint` links an episode to its show once that record arrives.
    public var pendingSync: Bool = false
    public var updatedAt: Date? = nil
    public var showKeyHint: String? = nil
    /// TheTVDB id from TMDb's external ids; fanart.tv keys shows by it.
    public var tvdbID: Int? = nil
    /// fanart.tv extras, fetched on demand by the detail screen and kept per device.
    public var logoURL: String? = nil
    public var extraBackdropURL: String? = nil
    public var extraArtCheckedAt: Date? = nil
    /// TMDb's film collection ("Spider-Man Collection"); films in one list on the film page.
    public var collectionID: Int? = nil
    public var collectionName: String? = nil
    public var collectionCheckedAt: Date? = nil
    /// TMDb production companies and keywords; `Universes` turns them into Marvel, Pixar, Star Wars…
    /// The file the user chose in Versions, by id; nil means the best resolution. Synced.
    public var preferredFileID: UUID? = nil
    /// Artwork the user picked in Edit artwork (absolute URLs, any source); nil means automatic.
    public var posterOverrideURL: String? = nil
    public var backdropOverrideURL: String? = nil
    public var logoOverrideURL: String? = nil
    public var studios: [String] = []
    /// TMDb logo paths parallel to `studios` ("" when none), for the Collections icons.
    public var studioLogos: [String] = []
    public var keywords: [String] = []
    /// Poster of the TMDb collection this film belongs to.
    public var collectionPosterPath: String? = nil
    public var universeCheckedAt: Date? = nil
    /// Fix Match left this item with no files. It is hidden now and deleted at the next launch:
    /// deleting it at once invalidated the object under an open detail page, which SwiftData
    /// punishes with a trap on the next property read (and `isDeleted` does not say so).
    public var pendingDeletion: Bool = false
    /// TMDb profile image paths, one per `cast` entry ("" when the person has no photo).
    public var castProfiles: [String] = []
    /// TMDb person ids, one per `cast` entry (0 when unknown), for the person page.
    public var castIDs: [Int] = []
    public var castPhotosCheckedAt: Date? = nil

    // Episode fields
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var airDate: Date?
    public var show: MediaItem?
    @Relationship(deleteRule: .cascade, inverse: \MediaItem.show) public var episodes: [MediaItem]
    public var seasonCount: Int?

    @Relationship(deleteRule: .nullify, inverse: \MediaFile.item) public var files: [MediaFile]

    public init(itemKey: String, kind: MediaKind, title: String, year: Int? = nil, tmdbID: Int? = nil, confidence: MatchConfidence) {
        self.itemKey = itemKey
        kindRaw = kind.rawValue
        self.title = title
        sortTitle = MediaItem.makeSortTitle(title)
        self.year = year
        self.tmdbID = tmdbID
        confidenceRaw = confidence.rawValue
        genres = []
        cast = []
        addedAt = Date()
        hidden = false
        episodes = []
        files = []
    }

    public var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .film }
    public var confidence: MatchConfidence {
        get { MatchConfidence(rawValue: confidenceRaw) ?? .unmatched }
        set { confidenceRaw = newValue.rawValue }
    }
    public var episodeCode: String? {
        guard let s = seasonNumber, let e = episodeNumber else { return nil }
        return MediaFormat.episodeCode(season: s, episode: e)
    }

    public static func makeSortTitle(_ title: String) -> String {
        let lower = title.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) { return String(lower.dropFirst(article.count)) }
        return lower
    }
}

/// Synced. One row per itemKey.
@Model
public final class WatchState {
    @Attribute(.unique) public var itemKey: String
    public var watched: Bool
    public var position: TimeInterval
    public var duration: TimeInterval
    public var updatedAt: Date
    public var deviceID: String
    public var lastPlayedAt: Date?
    /// Set when a local change is waiting to be pushed to CloudKit.
    public var pendingSync: Bool

    public init(itemKey: String, deviceID: String) {
        self.itemKey = itemKey
        watched = false
        position = 0
        duration = 0
        updatedAt = Date()
        self.deviceID = deviceID
        pendingSync = true
    }

    /// Fraction 0...1, nil when nothing meaningful has been watched.
    public var progress: Double? {
        guard duration > 0, position > 30 else { return nil }
        return min(1, position / duration)
    }
    public var isInProgress: Bool { !watched && (progress ?? 0) > 0.02 && (progress ?? 0) < 0.95 }
}

/// Synced, with a tombstone so removals propagate.
@Model
public final class Favourite {
    @Attribute(.unique) public var itemKey: String
    public var createdAt: Date
    public var deletedAt: Date?
    public var updatedAt: Date
    public var pendingSync: Bool

    public init(itemKey: String) {
        self.itemKey = itemKey
        createdAt = Date()
        updatedAt = Date()
        pendingSync = true
    }
    public var isActive: Bool { deletedAt == nil }
}

/// Synced. Manual match choices and hides. The file on disk is never touched.
@Model
public final class ItemOverride {
    /// Keyed by the file's unmatched key so the override follows the file across re-scans.
    @Attribute(.unique) public var fileKey: String
    public var forcedTMDbID: Int?
    public var forcedKindRaw: String?
    /// Fix Match → Anime: the AniDB entry the viewer chose. The matcher maps its episodes to TMDb
    /// through Anime-Lists (season and episode offsets), with `forcedTMDbID` as the plain fallback.
    public var forcedAniDBID: Int? = nil
    public var hidden: Bool
    public var updatedAt: Date
    public var pendingSync: Bool

    public init(fileKey: String) {
        self.fileKey = fileKey
        hidden = false
        updatedAt = Date()
        pendingSync = true
    }
    public var forcedKind: MediaKind? { forcedKindRaw.flatMap(MediaKind.init(rawValue:)) }
}

/// Synced.
@Model
public final class MediaCollection {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var itemKeys: [String]
    public var updatedAt: Date
    public var pendingSync: Bool
    /// Cover picked in Edit artwork (absolute URL); nil means a mosaic of its titles.
    public var artworkURL: String? = nil
    /// Up to four poster URLs the user ticked for the mosaic; empty means the first four titles.
    public var collageURLs: [String] = []

    public init(name: String) {
        id = UUID()
        self.name = name
        itemKeys = []
        updatedAt = Date()
        pendingSync = true
    }
}

/// CloudKit's system fields (record change tag, timestamps) for every record this device has sent or
/// received. An update is only accepted by CloudKit when it carries the current change tag, so without
/// this every second save of a record is rejected as a conflict.
@Model
public final class SyncRecordMeta {
    @Attribute(.unique) public var recordName: String
    public var systemFields: Data
    public init(recordName: String, systemFields: Data) {
        self.recordName = recordName
        self.systemFields = systemFields
    }
}

/// Artwork the user picked for a universe or film series. Those groups are computed from the films,
/// not stored, so the pick is keyed by the group's id ("u:Marvel", "s:<tmdb collection id>").
@Model
public final class GroupArtwork {
    @Attribute(.unique) public var groupID: String
    /// One picture (logo, poster or backdrop URL) for the card, or nil for a collage.
    public var url: String?
    /// Up to four poster URLs for the collage; empty means the group's first four films.
    public var collageURLs: [String]
    public var updatedAt: Date
    public var pendingSync: Bool

    public init(groupID: String) {
        self.groupID = groupID
        collageURLs = []
        updatedAt = Date()
        pendingSync = true
    }
    public var isEmpty: Bool { url == nil && collageURLs.isEmpty }
}

public enum LibrarySchema {
    public static let models: [any PersistentModel.Type] = [
        SourceRecord.self, FolderRule.self, MediaFile.self, MediaItem.self,
        WatchState.self, Favourite.self, ItemOverride.self, MediaCollection.self,
        SyncRecordMeta.self, GroupArtwork.self,
    ]

    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        // `cloudKitDatabase` defaults to `.automatic`: as soon as the app carries a CloudKit entitlement,
        // SwiftData tries to mirror this store to iCloud and refuses the schema (unique attributes are not
        // allowed there), so the container fails to open and the app dies at launch. Sync is CKSyncEngine's
        // job (Sources/Sync), not SwiftData's, so this store is explicitly local-only.
        let config = ModelConfiguration("Reel", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
#endif
