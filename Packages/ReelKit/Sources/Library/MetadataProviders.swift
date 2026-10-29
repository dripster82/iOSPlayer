import Foundation
import Metadata

/// Everything the matcher can consult. TMDb is the system of record for items and artwork; the
/// others only help find the right TMDb entry (TheTVDB via remote ids, AniDB + Anime-Lists via
/// their TMDb mapping), so nothing in the library ever depends on a provider the user has not set up.
public struct MetadataProviders: Sendable {
    public var tmdb: TMDbClient?
    public var tvdb: TVDBClient?
    public var anidb: AniDBTitles?
    public var animeLists: AnimeLists?
    /// Keyless second opinions for weak matches: Wikidata (films and shows), TVmaze (shows), Kitsu (anime).
    public var wikidata: WikidataClient?
    public var tvmaze: TVmazeClient?
    public var kitsu: KitsuClient?

    public init(tmdb: TMDbClient? = nil, tvdb: TVDBClient? = nil, anidb: AniDBTitles? = nil, animeLists: AnimeLists? = nil,
                wikidata: WikidataClient? = nil, tvmaze: TVmazeClient? = nil, kitsu: KitsuClient? = nil) {
        self.tmdb = tmdb
        self.tvdb = tvdb
        self.anidb = anidb
        self.animeLists = animeLists
        self.wikidata = wikidata
        self.tvmaze = tvmaze
        self.kitsu = kitsu
    }

    public static let none = MetadataProviders()
}
