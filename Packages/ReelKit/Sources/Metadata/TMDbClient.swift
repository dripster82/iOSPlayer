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

    public func searchMovies(query: String, year: Int? = nil) async throws -> [TMDbMovieSummary] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        let page: TMDbSearchPage<TMDbMovieSummary> = try await get("search/movie", items, label: "film search")
        return page.results
    }

    public func searchShows(query: String, year: Int? = nil) async throws -> [TMDbShowSummary] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year { items.append(URLQueryItem(name: "first_air_date_year", value: String(year))) }
        let page: TMDbSearchPage<TMDbShowSummary> = try await get("search/tv", items, label: "show search")
        return page.results
    }

    /// The TMDb show carrying a given TheTVDB id, if TMDb knows it.
    public func findShow(tvdbID: Int) async throws -> TMDbShowSummary? {
        let found: TMDbFindResult = try await get("find/\(tvdbID)", [URLQueryItem(name: "external_source", value: "tvdb_id")], label: "find")
        return found.tvResults.first
    }

    // MARK: - Details

    public func movie(id: Int) async throws -> TMDbMovieDetail {
        try await get("movie/\(id)", [URLQueryItem(name: "append_to_response", value: "credits")], label: "film")
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

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem], label: String) async throws -> T {
        guard !apiKey.isEmpty else { throw TMDbError.missingAPIKey }
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var q = query + [URLQueryItem(name: "language", value: language)]
        if let region { q.append(URLQueryItem(name: "region", value: region)) }
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
