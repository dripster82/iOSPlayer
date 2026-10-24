import Foundation

// Decodable shapes for the subset of TMDb v3 the app uses. Field names follow the API.

public struct TMDbSearchPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public var page: Int
    public var results: [Item]
    public var totalResults: Int

    enum CodingKeys: String, CodingKey { case page, results, totalResults = "total_results" }
}

public struct TMDbMovieSummary: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var releaseDate: String?
    public var popularity: Double?
    public var voteAverage: Double?
    public var genreIDs: [Int]?

    public var year: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }

    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity
        case originalTitle = "original_title"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case genreIDs = "genre_ids"
    }
}

public struct TMDbShowSummary: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var firstAirDate: String?
    public var popularity: Double?
    public var voteAverage: Double?
    public var genreIDs: [Int]?

    public var year: Int? { firstAirDate.flatMap { Int($0.prefix(4)) } }

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIDs = "genre_ids"
    }
}

public struct TMDbGenre: Decodable, Sendable, Hashable { public var id: Int; public var name: String }

public struct TMDbCastMember: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public var order: Int?
    enum CodingKeys: String, CodingKey { case id, name, character, order; case profilePath = "profile_path" }
}

public struct TMDbCredits: Decodable, Sendable { public var cast: [TMDbCastMember] }

public struct TMDbMovieDetail: Decodable, Sendable {
    public var id: Int
    public var title: String
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var releaseDate: String?
    public var runtime: Int?
    public var voteAverage: Double?
    public var genres: [TMDbGenre]?
    public var credits: TMDbCredits?
    public var belongsToCollection: TMDbCollectionRef?
    public var imdbID: String?

    public var year: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }

    enum CodingKeys: String, CodingKey {
        case id, title, overview, runtime, genres, credits
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case belongsToCollection = "belongs_to_collection"
        case imdbID = "imdb_id"
    }
}

public struct TMDbCollectionDetail: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var posterPath: String?
    public var parts: [TMDbMovieSummary]
    enum CodingKeys: String, CodingKey { case id, name, overview, parts; case posterPath = "poster_path" }
}

public struct TMDbCollectionRef: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var posterPath: String?
    enum CodingKeys: String, CodingKey { case id, name; case posterPath = "poster_path" }
}

public struct TMDbSeasonSummary: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var seasonNumber: Int
    public var name: String
    public var episodeCount: Int?
    public var posterPath: String?
    public var airDate: String?
    enum CodingKeys: String, CodingKey { case id, name; case seasonNumber = "season_number"; case episodeCount = "episode_count"; case posterPath = "poster_path"; case airDate = "air_date" }
}

public struct TMDbShowDetail: Decodable, Sendable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var firstAirDate: String?
    public var voteAverage: Double?
    public var genres: [TMDbGenre]?
    public var seasons: [TMDbSeasonSummary]?
    public var numberOfSeasons: Int?
    public var episodeRunTime: [Int]?
    public var credits: TMDbCredits?
    public var externalIDs: TMDbExternalIDs?

    public var year: Int? { firstAirDate.flatMap { Int($0.prefix(4)) } }

    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres, seasons, credits
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case numberOfSeasons = "number_of_seasons"
        case episodeRunTime = "episode_run_time"
        case externalIDs = "external_ids"
    }
}

public struct TMDbExternalIDs: Decodable, Sendable {
    public var imdbID: String?
    public var tvdbID: Int?
    enum CodingKeys: String, CodingKey { case imdbID = "imdb_id"; case tvdbID = "tvdb_id" }
}

public struct TMDbEpisode: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var airDate: String?
    public var stillPath: String?
    public var runtime: Int?
    public var voteAverage: Double?
    enum CodingKeys: String, CodingKey {
        case id, name, overview, runtime
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case airDate = "air_date"
        case stillPath = "still_path"
        case voteAverage = "vote_average"
    }
}

public struct TMDbSeasonDetail: Decodable, Sendable {
    public var id: Int
    public var name: String
    public var seasonNumber: Int
    public var overview: String?
    public var posterPath: String?
    public var episodes: [TMDbEpisode]
    enum CodingKeys: String, CodingKey { case id, name, overview, episodes; case seasonNumber = "season_number"; case posterPath = "poster_path" }
}

/// `/find/{id}` response: TMDb entries matching an external (TheTVDB, IMDb) id.
public struct TMDbFindResult: Decodable, Sendable {
    public var tvResults: [TMDbShowSummary]
    public var movieResults: [TMDbMovieSummary]
    enum CodingKeys: String, CodingKey { case tvResults = "tv_results"; case movieResults = "movie_results" }
}
