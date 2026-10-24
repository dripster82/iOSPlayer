import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TVDBError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case http(Int)
    case decoding(String)
    case offline

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No TheTVDB API key is set."
        case .http(let code): "TheTVDB returned HTTP \(code)."
        case .decoding(let what): "Couldn't read TheTVDB's response for \(what)."
        case .offline: "TheTVDB is unreachable."
        }
    }
}

public struct TVDBSeries: Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var year: Int?
    public var overview: String?
    /// Absolute URL to a poster (TheTVDB hosts artwork itself).
    public var imageURL: String?
    public var tmdbID: Int?
    public var imdbID: String?
}

/// TheTVDB v4 client: used as a fallback search when TMDb does not know a show, and to bridge to
/// TMDb through the remote IDs TheTVDB records. Needs the user's own project key (v4 keys are per
/// project; a subscriber PIN is optional). Attribution: "Metadata provided by TheTVDB".
public actor TVDBClient {
    public static let apiBase = URL(string: "https://api4.thetvdb.com/v4")!

    private let apiKey: String
    private let pin: String?
    private let transport: HTTPTransport
    private let cache: MetadataCache
    private let limiter: RateLimiter
    private var token: String?
    private let decoder = JSONDecoder()

    public init(apiKey: String, pin: String? = nil, transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 20, window: 10)) {
        self.apiKey = apiKey
        self.pin = (pin?.isEmpty ?? true) ? nil : pin
        self.transport = transport
        self.cache = cache
        self.limiter = limiter
    }

    /// Every poster, background and clear logo TheTVDB holds for a series (absolute URLs), for the
    /// artwork picker. Type ids per TheTVDB's artwork types: 2 poster, 3 background, 23 clear logo.
    public struct Artwork: Sendable, Hashable { public var posters: [String]; public var backgrounds: [String]; public var logos: [String] }
    public func artwork(seriesID: Int) async throws -> Artwork {
        let page: Envelope<ExtendedSeries> = try await get("series/\(seriesID)/extended", [URLQueryItem(name: "meta", value: "translations")], label: "series artwork")
        let arts = (page.data.artworks ?? []).sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        func urls(_ type: Int) -> [String] { arts.filter { $0.type == type }.compactMap(\.image).prefix(20).map { $0 } }
        return Artwork(posters: urls(2), backgrounds: urls(3), logos: urls(23))
    }

    public func searchSeries(query: String, year: Int? = nil) async throws -> [TVDBSeries] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "series"), URLQueryItem(name: "limit", value: "10")]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        let page: Envelope<[SearchResult]> = try await get("search", items, label: "series search")
        return page.data.compactMap { r in
            guard let id = Int(r.tvdbID ?? "") else { return nil }
            return TVDBSeries(id: id, name: r.name, year: r.year.flatMap { Int($0) }, overview: r.overview, imageURL: r.imageURL,
                              tmdbID: r.remoteIDs?.first { $0.sourceName == "TheMovieDB.com" }.flatMap { Int($0.id) },
                              imdbID: r.remoteIDs?.first { $0.sourceName == "IMDB" }?.id)
        }
    }

    // MARK: - Plumbing

    private struct Envelope<T: Decodable>: Decodable { var data: T }
    private struct LoginData: Decodable { var token: String }
    private struct ExtendedSeries: Decodable { var artworks: [ArtworkRow]? }
    private struct ArtworkRow: Decodable { var image: String?; var type: Int?; var score: Double? }
    private struct RemoteID: Decodable { var id: String; var sourceName: String? }
    private struct SearchResult: Decodable {
        var tvdbID: String?
        var name: String
        var year: String?
        var overview: String?
        var imageURL: String?
        var remoteIDs: [RemoteID]?
        enum CodingKeys: String, CodingKey { case name, year, overview; case tvdbID = "tvdb_id"; case imageURL = "image_url"; case remoteIDs = "remote_ids" }
    }

    private func ensureToken() async throws -> String {
        if let token { return token }
        guard !apiKey.isEmpty else { throw TVDBError.missingAPIKey }
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: String] = ["apikey": apiKey]
        if let pin { body["pin"] = pin }
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 20
        await limiter.acquire()
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TVDBError.http(http.statusCode) }
        let login: Envelope<LoginData>
        do { login = try decoder.decode(Envelope<LoginData>.self, from: data) } catch { throw TVDBError.decoding("login") }
        token = login.data.token
        return login.data.token
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem], label: String) async throws -> T {
        guard !apiKey.isEmpty else { throw TVDBError.missingAPIKey }
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        let url = comps.url!
        if let entry = await cache.read(url.absoluteString), entry.isFresh { return try decode(entry.data, label: label) }

        let token = try await ensureToken()
        await limiter.acquire()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await transport.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 { self.token = nil }
                if !(200..<300).contains(http.statusCode) { throw TVDBError.http(http.statusCode) }
            }
            let value: T = try decode(data, label: label)
            await cache.write(url.absoluteString, data: data)
            return value
        } catch let error as TVDBError {
            throw error
        } catch {
            if let entry = await cache.read(url.absoluteString) { return try decode(entry.data, label: label) }
            throw TVDBError.offline
        }
    }

    private func decode<T: Decodable>(_ data: Data, label: String) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw TVDBError.decoding(label) }
    }
}
