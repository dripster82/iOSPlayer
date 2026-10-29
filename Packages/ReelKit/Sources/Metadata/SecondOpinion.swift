import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A title another database knows, with the ids that let it be compared to TMDb's answer.
/// Wikidata carries TMDb ids directly; TVmaze gives IMDb and TheTVDB ids that TMDb's find endpoint
/// turns into a TMDb id; Kitsu gives the AniDB id Reel's anime path works from.
public struct SecondOpinionHit: Sendable, Equatable {
    public var source: String
    public var title: String
    public var year: Int?
    public var tmdbID: Int?
    public var imdbID: String?
    public var tvdbID: Int?
    public var anidbID: Int?
    public init(source: String, title: String, year: Int? = nil, tmdbID: Int? = nil, imdbID: String? = nil, tvdbID: Int? = nil, anidbID: Int? = nil) {
        self.source = source; self.title = title; self.year = year; self.tmdbID = tmdbID; self.imdbID = imdbID; self.tvdbID = tvdbID; self.anidbID = anidbID
    }
}

/// GET JSON from a keyless API, through the shared cache and a per-service rate limiter, with the
/// User-Agent these services ask for. Errors are the caller's to swallow: a second opinion that
/// cannot be fetched is simply no opinion.
struct KeylessJSON: Sendable {
    static let userAgent = "Reel/1.0 (https://dripster82.github.io/iOSPlayer; paul@ketelle.co.uk)"
    let transport: HTTPTransport
    let cache: MetadataCache
    let limiter: RateLimiter
    let accept: String

    init(transport: HTTPTransport, cache: MetadataCache, limiter: RateLimiter, accept: String = "application/json") {
        self.transport = transport; self.cache = cache; self.limiter = limiter; self.accept = accept
    }

    func object(_ url: URL) async throws -> Any {
        let key = url.absoluteString
        if let entry = await cache.read(key), entry.isFresh { return try JSONSerialization.jsonObject(with: entry.data) }
        await limiter.acquire()
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await transport.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TMDbError.http(http.statusCode) }
            let object = try JSONSerialization.jsonObject(with: data)
            await cache.write(key, data: data)
            return object
        } catch {
            if let entry = await cache.read(key) { return try JSONSerialization.jsonObject(with: entry.data) }
            throw error
        }
    }
}

/// Normalises a title the way the scorer does, so "The Lego Movie" and "The LEGO Movie" agree.
public func opinionNormalise(_ s: String) -> String { MatchScorer.normalise(s) }

// MARK: - Wikidata

/// Wikidata, for films and shows: its entities carry TMDb ids (P4947 films, P4983 series), an
/// IMDb id (P345) and a release year (P577, or P580 for a series), so an entity with the file's
/// title and year that names the same TMDb id is an independent confirmation.
public actor WikidataClient {
    public static let apiBase = URL(string: "https://www.wikidata.org/w/api.php")!
    private let fetch: KeylessJSON

    public init(transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 20, window: 10)) {
        fetch = KeylessJSON(transport: transport, cache: cache, limiter: limiter)
    }

    public func searchFilms(title: String) async throws -> [SecondOpinionHit] { try await search(title: title, film: true) }
    public func searchShows(title: String) async throws -> [SecondOpinionHit] { try await search(title: title, film: false) }

    private func search(title: String, film: Bool) async throws -> [SecondOpinionHit] {
        var c = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "action", value: "wbsearchentities"), .init(name: "search", value: title), .init(name: "language", value: "en"),
                        .init(name: "uselang", value: "en"), .init(name: "type", value: "item"), .init(name: "limit", value: "10"), .init(name: "format", value: "json")]
        let found = try await fetch.object(c.url!) as? [String: Any]
        let ids = ((found?["search"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return [] }
        var e = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
        e.queryItems = [.init(name: "action", value: "wbgetentities"), .init(name: "ids", value: ids.joined(separator: "|")), .init(name: "props", value: "claims|labels"),
                        .init(name: "languages", value: "en"), .init(name: "format", value: "json")]
        let got = try await fetch.object(e.url!) as? [String: Any]
        let entities = (got?["entities"] as? [String: Any]) ?? [:]
        return ids.compactMap { id -> SecondOpinionHit? in
            guard let entity = entities[id] as? [String: Any], let claims = entity["claims"] as? [String: Any] else { return nil }
            let tmdbProperty = film ? "P4947" : "P4983"
            guard let tmdbRaw = Self.firstValue(claims, tmdbProperty) as? String, let tmdbID = Int(tmdbRaw) else { return nil }
            let label = ((entity["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String ?? ""
            let when = (Self.firstValue(claims, "P577") as? [String: Any])?["time"] as? String ?? (Self.firstValue(claims, "P580") as? [String: Any])?["time"] as? String
            let year = when.flatMap { Int($0.dropFirst().prefix(4)) }
            return SecondOpinionHit(source: "Wikidata", title: label, year: year, tmdbID: tmdbID, imdbID: Self.firstValue(claims, "P345") as? String)
        }
    }

    /// The first statement's value for a property: a string for an external id, a dictionary for a date.
    static func firstValue(_ claims: [String: Any], _ property: String) -> Any? {
        guard let statements = claims[property] as? [[String: Any]] else { return nil }
        // Prefer a preferred-rank statement (the original release) over normal ones; skip deprecated.
        let ranked = statements.sorted { ($0["rank"] as? String == "preferred" ? 0 : 1) < ($1["rank"] as? String == "preferred" ? 0 : 1) }
        for s in ranked where (s["rank"] as? String) != "deprecated" {
            if let v = ((s["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] { return v }
        }
        return nil
    }
}

// MARK: - TVmaze

/// TVmaze, for shows: an independent TV database with a premiere date and IMDb and TheTVDB ids per
/// show. TMDb's find endpoint turns either id into a TMDb show id for the comparison.
public actor TVmazeClient {
    public static let apiBase = URL(string: "https://api.tvmaze.com")!
    private let fetch: KeylessJSON

    public init(transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 15, window: 10)) {
        fetch = KeylessJSON(transport: transport, cache: cache, limiter: limiter)
    }

    public func searchShows(title: String) async throws -> [SecondOpinionHit] {
        var c = URLComponents(url: Self.apiBase.appendingPathComponent("search/shows"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "q", value: title)]
        let rows = (try await fetch.object(c.url!) as? [[String: Any]]) ?? []
        return rows.compactMap { row -> SecondOpinionHit? in
            guard let show = row["show"] as? [String: Any], let name = show["name"] as? String else { return nil }
            let externals = show["externals"] as? [String: Any]
            let premiered = show["premiered"] as? String
            return SecondOpinionHit(source: "TVmaze", title: name, year: premiered.flatMap { Int($0.prefix(4)) },
                                    imdbID: externals?["imdb"] as? String, tvdbID: externals?["thetvdb"] as? Int)
        }
    }
}

// MARK: - Kitsu

/// Kitsu, for anime: a title search whose results carry mappings to AniDB, so a hit can be compared
/// to the AniDB entry Reel's anime path resolved, and can break a tie between two entries.
public actor KitsuClient {
    public static let apiBase = URL(string: "https://kitsu.io/api/edge")!
    private let fetch: KeylessJSON

    public init(transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 15, window: 10)) {
        fetch = KeylessJSON(transport: transport, cache: cache, limiter: limiter, accept: "application/vnd.api+json")
    }

    public func searchAnime(title: String) async throws -> [SecondOpinionHit] {
        var c = URLComponents(url: Self.apiBase.appendingPathComponent("anime"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "filter[text]", value: title), .init(name: "page[limit]", value: "5"), .init(name: "include", value: "mappings"), .init(name: "fields[mappings]", value: "externalSite,externalId")]
        let page = try await fetch.object(c.url!) as? [String: Any]
        // Mapping id → AniDB id, from the included resources.
        var anidbByMapping: [String: Int] = [:]
        for inc in (page?["included"] as? [[String: Any]]) ?? [] where inc["type"] as? String == "mappings" {
            guard let id = inc["id"] as? String, let attrs = inc["attributes"] as? [String: Any],
                  attrs["externalSite"] as? String == "anidb", let ext = attrs["externalId"] as? String, let aid = Int(ext) else { continue }
            anidbByMapping[id] = aid
        }
        return ((page?["data"] as? [[String: Any]]) ?? []).compactMap { row -> SecondOpinionHit? in
            guard let attrs = row["attributes"] as? [String: Any] else { return nil }
            let title = attrs["canonicalTitle"] as? String ?? ((attrs["titles"] as? [String: Any])?["en"] as? String) ?? ""
            let start = attrs["startDate"] as? String
            let mappingIDs = ((((row["relationships"] as? [String: Any])?["mappings"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            let aid = mappingIDs.compactMap { anidbByMapping[$0] }.first
            return SecondOpinionHit(source: "Kitsu", title: title, year: start.flatMap { Int($0.prefix(4)) }, anidbID: aid)
        }
    }
}
