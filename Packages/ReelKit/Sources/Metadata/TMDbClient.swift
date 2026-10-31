import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so tests can inject canned responses.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public enum TMDbError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case http(Int)
    case offlineNoCache
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No TMDb API key is set. Add one in Settings > Library."
        case .http(let code): "TMDb returned HTTP \(code)."
        case .offlineNoCache: "Metadata unavailable and nothing cached for this item."
        case .decoding(let what): "Couldn't read TMDb's response for \(what)."
        }
    }
}

/// TMDb v3 client. Every GET goes through the rate limiter and the disk cache.
/// Attribution requirement: the About screen shows the TMDb logo and the required notice.
public actor TMDbClient {
    public static let apiBase = URL(string: "https://api.themoviedb.org/3")!

    private let apiKey: String
    private let language: String
    private let region: String?
    private let transport: HTTPTransport
    private let cache: MetadataCache
    private let limiter: RateLimiter
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - apiKey: a v3 API key (free for non-commercial use).
    ///   - language: ISO 639-1 with optional region, e.g. "en-GB".
    public init(apiKey: String, language: String = "en-GB", region: String? = "GB", transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter()) {
        self.apiKey = apiKey
        self.language = language
        self.region = region
        self.transport = transport
        self.cache = cache
        self.limiter = limiter
    }

    // MARK: - Search

    /// Searches go without the region: with one, TMDb reports each result's release date in that
    /// region (Aladdin becomes 1993, Sing 2017 in the UK), and the scorer then prefers a same-named
    /// obscurity from the year on the file. The primary release year is the one file names carry.
    public func searchMovies(query: String, year: Int? = nil) async throws -> [TMDbMovieSummary] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        let page: TMDbSearchPage<TMDbMovieSummary> = try await get("search/movie", items, label: "film search", withRegion: false)
        return page.results
    }

    public func searchShows(query: String, year: Int? = nil) async throws -> [TMDbShowSummary] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year { items.append(URLQueryItem(name: "first_air_date_year", value: String(year))) }
        let page: TMDbSearchPage<TMDbShowSummary> = try await get("search/tv", items, label: "show search", withRegion: false)
        return page.results
    }

    /// The TMDb show carrying a given TheTVDB id, if TMDb knows it.
    public func findShow(tvdbID: Int) async throws -> TMDbShowSummary? {
        let found: TMDbFindResult = try await get("find/\(tvdbID)", [URLQueryItem(name: "external_source", value: "tvdb_id")], label: "find")
        return found.tvResults.first
    }

    /// The TMDb show carrying a given IMDb id ("tt1234567"), if TMDb knows it.
    public func findShow(imdbID: String) async throws -> TMDbShowSummary? {
        let found: TMDbFindResult = try await get("find/\(imdbID)", [URLQueryItem(name: "external_source", value: "imdb_id")], label: "find")
        return found.tvResults.first
    }

    /// The TMDb film carrying a given IMDb id, if TMDb knows it.
    public func findMovie(imdbID: String) async throws -> TMDbMovieSummary? {
        let found: TMDbFindResult = try await get("find/\(imdbID)", [URLQueryItem(name: "external_source", value: "imdb_id")], label: "find")
        return found.movieResults.first
    }

    // MARK: - Details

    /// Every poster, backdrop and logo TMDb holds for a film or show, in the user's language and
    /// language-neutral, best voted first.
    public func images(id: Int, isShow: Bool) async throws -> TMDbImages {
        let lang = String(language.prefix(2))
        var imgs: TMDbImages = try await get("\(isShow ? "tv" : "movie")/\(id)/images", [URLQueryItem(name: "include_image_language", value: "\(lang),null,en")], label: "images")
        func rank(_ a: [TMDbImage]?) -> [TMDbImage] {
            (a ?? []).sorted { l, r in
                let lp = l.language == lang ? 0 : (l.language == nil ? 1 : 2), rp = r.language == lang ? 0 : (r.language == nil ? 1 : 2)
                return lp != rp ? lp < rp : (l.voteAverage ?? 0) > (r.voteAverage ?? 0)
            }
        }
        imgs.posters = rank(imgs.posters); imgs.backdrops = rank(imgs.backdrops); imgs.logos = rank(imgs.logos)
        return imgs
    }

    /// Posters and backdrops TMDb holds for a film collection itself (not its films).
    public func collectionImages(id: Int) async throws -> TMDbImages {
        let lang = String(language.prefix(2))
        var imgs: TMDbImages = try await get("collection/\(id)/images", [URLQueryItem(name: "include_image_language", value: "\(lang),null,en")], label: "collection images")
        let rank: ([TMDbImage]?) -> [TMDbImage] = { ($0 ?? []).sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) } }
        imgs.posters = rank(imgs.posters); imgs.backdrops = rank(imgs.backdrops)
        return imgs
    }

    /// TMDb's recommendations for a film or show: (id, title, year, poster path, isShow).
    public struct Recommendation: Sendable, Identifiable, Hashable { public var id: Int; public var title: String; public var year: Int?; public var posterPath: String?; public var isShow: Bool }
    public func recommendations(id: Int, isShow: Bool) async throws -> [Recommendation] {
        if isShow {
            let page: TMDbSearchPage<TMDbShowSummary> = try await get("tv/\(id)/recommendations", [], label: "recommendations")
            return page.results.prefix(20).map { Recommendation(id: $0.id, title: $0.name, year: $0.year, posterPath: $0.posterPath, isShow: true) }
        } else {
            let page: TMDbSearchPage<TMDbMovieSummary> = try await get("movie/\(id)/recommendations", [], label: "recommendations")
            return page.results.prefix(20).map { Recommendation(id: $0.id, title: $0.title, year: $0.year, posterPath: $0.posterPath, isShow: false) }
        }
    }

    /// Trailers and teasers on YouTube, official trailers first.
    public func trailers(id: Int, isShow: Bool) async throws -> [TMDbVideo] {
        let v: TMDbVideos = try await get("\(isShow ? "tv" : "movie")/\(id)/videos", [], label: "videos")
        let rank: (TMDbVideo) -> Int = { ($0.type == "Trailer" ? 0 : $0.type == "Teaser" ? 1 : 2) + ($0.official == true ? 0 : 10) }
        return v.results.filter { $0.youTubeURL != nil }.sorted { rank($0) < rank($1) }
    }

    /// Everything a person acted in, films and TV together. Crew credits are left out.
    public func personCredits(id: Int) async throws -> [TMDbPersonCredit] {
        let credits: TMDbPersonCredits = try await get("person/\(id)/combined_credits", [], label: "person credits")
        return credits.cast
    }

    /// One person: the name and current profile photo, for cast recorded without a photo.
    public func person(id: Int) async throws -> TMDbPersonSummary {
        try await get("person/\(id)", [], label: "person")
    }

    /// For cast members recorded before their TMDb ids were kept: find the person by name.
    public func searchPeople(query: String) async throws -> [TMDbPersonSummary] {
        let page: TMDbSearchPage<TMDbPersonSummary> = try await get("search/person", [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")], label: "person search")
        return page.results
    }

    /// A film collection (sequels, a trilogy) and every film TMDb lists in it.
    public func collection(id: Int) async throws -> TMDbCollectionDetail {
        try await get("collection/\(id)", [], label: "collection")
    }

    public func movie(id: Int) async throws -> TMDbMovieDetail {
        try await get("movie/\(id)", [URLQueryItem(name: "append_to_response", value: "credits,keywords")], label: "film")
    }

    public func show(id: Int) async throws -> TMDbShowDetail {
        try await get("tv/\(id)", [URLQueryItem(name: "append_to_response", value: "credits,external_ids")], label: "show")
    }

    public func season(showID: Int, season: Int) async throws -> TMDbSeasonDetail {
        try await get("tv/\(showID)/season/\(season)", [], label: "season")
    }

    public func episode(showID: Int, season: Int, episode: Int) async throws -> TMDbEpisode {
        try await get("tv/\(showID)/season/\(season)/episode/\(episode)", [], label: "episode")
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem], label: String, withRegion: Bool = true) async throws -> T {
        guard !apiKey.isEmpty else { throw TMDbError.missingAPIKey }
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var q = query + [URLQueryItem(name: "language", value: language)]
        if withRegion, let region { q.append(URLQueryItem(name: "region", value: region)) }
        comps.queryItems = q
        let cacheKey = comps.url!.absoluteString
        comps.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        let url = comps.url!

        if let entry = await cache.read(cacheKey), entry.isFresh {
            return try decode(entry.data, label: label)
        }

        await limiter.acquire()
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await transport.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw TMDbError.http(http.statusCode)
            }
            let value: T = try decode(data, label: label)
            await cache.write(cacheKey, data: data)
            return value
        } catch let error as TMDbError {
            throw error
        } catch {
            // Network failure: serve stale cache rather than nothing.
            if let entry = await cache.read(cacheKey) { return try decode(entry.data, label: label) }
            throw TMDbError.offlineNoCache
        }
    }

    private func decode<T: Decodable>(_ data: Data, label: String) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw TMDbError.decoding(label) }
    }
}
