import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A book one of the audiobook catalogues knows. Audible's catalogue (keyless) carries everything a
/// book page wants: the ASIN, authors, narrators, the series and the book's place in it, the
/// summary, length and a large cover. Audnexus (Audible's data cleaned by the Audiobookshelf
/// community) adds a plain-text description and genres for an ASIN. Apple Books is the fallback
/// for a title Audible does not sell: author, description, cover, year; no narrator or series.
public struct AudiobookHit: Sendable, Equatable, Identifiable {
    public var id: String { asin ?? "apple:\(appleID ?? 0)" }
    public var source: String
    public var asin: String?
    public var appleID: Int?
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var series: String?
    /// "3", or "1.5" for a novella between two books: kept as the catalogue wrote it.
    public var seriesPosition: String?
    public var year: Int?
    public var runtimeMinutes: Int?
    /// Plain text; the catalogues send HTML.
    public var summary: String?
    public var coverURL: String?
    public var publisher: String?
    public var genres: [String]

    public init(source: String, asin: String? = nil, appleID: Int? = nil, title: String, subtitle: String? = nil, authors: [String] = [], narrators: [String] = [],
                series: String? = nil, seriesPosition: String? = nil, year: Int? = nil, runtimeMinutes: Int? = nil, summary: String? = nil, coverURL: String? = nil,
                publisher: String? = nil, genres: [String] = []) {
        self.source = source; self.asin = asin; self.appleID = appleID; self.title = title; self.subtitle = subtitle; self.authors = authors; self.narrators = narrators
        self.series = series; self.seriesPosition = seriesPosition; self.year = year; self.runtimeMinutes = runtimeMinutes; self.summary = summary; self.coverURL = coverURL
        self.publisher = publisher; self.genres = genres
    }

    /// The whole number of "3" or "3.0"; nil for "1.5".
    public var seriesIndex: Int? {
        guard let p = seriesPosition?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let n = Int(p) { return n }
        if let d = Double(p), d == d.rounded() { return Int(d) }
        return nil
    }
    public var authorLine: String? { authors.isEmpty ? nil : authors.joined(separator: ", ") }
    public var narratorLine: String? { narrators.isEmpty ? nil : narrators.joined(separator: ", ") }
}

/// Strips tags and the common entities from a catalogue's HTML summary.
func plainText(_ html: String) -> String {
    var s = html.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</li>"#, with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–")] {
        s = s.replacingOccurrences(of: e, with: c)
    }
    s = s.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Audible catalogue

/// Audible's public catalogue search, the one its own apps use: no key, a title (and author) in,
/// products with every field out. A region picks the store, since a title's ASIN differs between
/// them and a UK listener wants the UK edition's narrator.
public actor AudibleCatalogClient {
    public static let regions: [(code: String, domain: String, name: String)] = [
        ("uk", "audible.co.uk", "United Kingdom"), ("us", "audible.com", "United States"), ("ca", "audible.ca", "Canada"), ("au", "audible.com.au", "Australia"),
        ("de", "audible.de", "Germany"), ("fr", "audible.fr", "France"), ("it", "audible.it", "Italy"), ("es", "audible.es", "Spain"), ("jp", "audible.co.jp", "Japan"), ("in", "audible.in", "India"),
    ]
    public static func domain(for region: String) -> String { regions.first { $0.code == region }?.domain ?? "audible.co.uk" }

    private let fetch: KeylessJSON
    public let region: String

    public init(region: String = "uk", transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 10, window: 10)) {
        self.region = region
        fetch = KeylessJSON(transport: transport, cache: cache, limiter: limiter)
    }

    static let responseGroups = "contributors,series,media,product_desc,product_attrs,product_extended_attrs"

    private func url(_ path: String, _ items: [URLQueryItem]) -> URL {
        var c = URLComponents(string: "https://api.\(Self.domain(for: region))/1.0/catalog/\(path)")!
        c.queryItems = items + [.init(name: "response_groups", value: Self.responseGroups), .init(name: "image_sizes", value: "500,1000")]
        return c.url!
    }

    public func search(title: String, author: String? = nil, limit: Int = 10) async throws -> [AudiobookHit] {
        var items: [URLQueryItem] = [.init(name: "title", value: title), .init(name: "num_results", value: String(limit)), .init(name: "products_sort_by", value: "Relevance")]
        if let author, !author.isEmpty { items.append(.init(name: "author", value: author)) }
        let object = try await fetch.object(url("products", items)) as? [String: Any]
        let products = (object?["products"] as? [[String: Any]]) ?? []
        return products.compactMap(Self.hit)
    }

    public func book(asin: String) async throws -> AudiobookHit? {
        let object = try await fetch.object(url("products/\(asin)", [])) as? [String: Any]
        return (object?["product"] as? [String: Any]).flatMap(Self.hit)
    }

    static func hit(_ p: [String: Any]) -> AudiobookHit? {
        guard let asin = p["asin"] as? String, let title = p["title"] as? String else { return nil }
        // "Ben Aaranovitch - introduction", "X - translator": contributors with a role are not the author.
        func names(_ key: String) -> [String] {
            ((p[key] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                .filter { $0.range(of: #"(?i)\s[-–]\s*(introduction|foreword|afterword|translator|editor|illustrator|contributor|adapt\w*)\s*$"#, options: .regularExpression) == nil }
        }
        let series = (p["series"] as? [[String: Any]])?.first
        let images = p["product_images"] as? [String: Any]
        let cover = (images?["1000"] ?? images?["500"]) as? String
        let summary = (p["publisher_summary"] as? String) ?? (p["merchandising_summary"] as? String)
        let release = (p["release_date"] as? String) ?? (p["issue_date"] as? String)
        var subtitle = p["subtitle"] as? String
        // "(Long Earth 3)" as a subtitle repeats the series line.
        if let s = subtitle, let name = series?["title"] as? String, MatchScorer.normalise(s).contains(MatchScorer.normalise(name)) { subtitle = nil }
        return AudiobookHit(source: "Audible", asin: asin, title: title, subtitle: subtitle, authors: names("authors"), narrators: names("narrators"),
                            series: series?["title"] as? String, seriesPosition: (series?["sequence"] as? String) ?? (series?["sequence"] as? Int).map(String.init),
                            year: release.flatMap { Int($0.prefix(4)) }, runtimeMinutes: p["runtime_length_min"] as? Int,
                            summary: summary.map(plainText), coverURL: cover, publisher: p["publisher_name"] as? String, genres: [])
    }
}

// MARK: - Audnexus

/// Audnexus: Audible's record for an ASIN, cleaned up (plain description, genres, a full-size cover,
/// a rating). Region-bound like Audible itself; a title missing from the region is no answer.
public actor AudnexusClient {
    public static let apiBase = URL(string: "https://api.audnex.us")!
    private let fetch: KeylessJSON
    public let region: String

    public init(region: String = "uk", transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 10, window: 10)) {
        self.region = region
        fetch = KeylessJSON(transport: transport, cache: cache, limiter: limiter)
    }

    public func book(asin: String) async throws -> AudiobookHit? {
        var c = URLComponents(url: Self.apiBase.appendingPathComponent("books/\(asin)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "region", value: region)]
        guard let p = try await fetch.object(c.url!) as? [String: Any], p["error"] == nil, let title = p["title"] as? String else { return nil }
        func names(_ key: String) -> [String] { ((p[key] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String } }
        let series = p["seriesPrimary"] as? [String: Any]
        let genres = ((p["genres"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "genre" }.compactMap { $0["name"] as? String }
        let tags = ((p["genres"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        return AudiobookHit(source: "Audnexus", asin: asin, title: title, subtitle: p["subtitle"] as? String, authors: names("authors"), narrators: names("narrators"),
                            series: series?["name"] as? String, seriesPosition: series?["position"] as? String,
                            year: (p["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }, runtimeMinutes: p["runtimeLengthMin"] as? Int,
                            summary: ((p["summary"] as? String).map(plainText)) ?? (p["description"] as? String), coverURL: p["image"] as? String,
                            publisher: p["publisherName"] as? String, genres: genres.isEmpty ? Array(tags.prefix(4)) : genres)
    }
}

// MARK: - Apple Books

/// The iTunes Search API's audiobook catalogue: a fallback with author, description, cover and year.
public actor AppleBooksClient {
    public static let apiBase = URL(string: "https://itunes.apple.com/search")!
    private let fetch: KeylessJSON
    public let country: String

    public init(country: String = "gb", transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache(), limiter: RateLimiter = RateLimiter(limit: 10, window: 60)) {
        self.country = country
        fetch = KeylessJSON(transport: transport, cache: cache, limiter: limiter, accept: "*/*")
    }

    public func search(_ term: String, limit: Int = 10) async throws -> [AudiobookHit] {
        var c = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "media", value: "audiobook"), .init(name: "term", value: term), .init(name: "limit", value: String(limit)), .init(name: "country", value: country)]
        let object = try await fetch.object(c.url!) as? [String: Any]
        return ((object?["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["collectionId"] as? Int, let name = r["collectionName"] as? String else { return nil }
            let cover = (r["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return AudiobookHit(source: "Apple Books", appleID: id, title: name, authors: (r["artistName"] as? String).map { [$0] } ?? [],
                                year: (r["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }, summary: (r["description"] as? String).map(plainText),
                                coverURL: cover, genres: (r["primaryGenreName"] as? String).map { [$0] } ?? [])
        }
    }
}

// MARK: - Together

/// The three catalogues as one lookup: Audible for the search, Audnexus for the detail of a chosen
/// ASIN, Apple Books when Audible has nothing.
public struct AudiobookLookup: Sendable {
    public let audible: AudibleCatalogClient
    public let audnexus: AudnexusClient
    public let apple: AppleBooksClient

    public init(region: String = "uk") {
        audible = AudibleCatalogClient(region: region)
        audnexus = AudnexusClient(region: region)
        apple = AppleBooksClient(country: region == "uk" ? "gb" : region)
    }
    public init(audible: AudibleCatalogClient, audnexus: AudnexusClient, apple: AppleBooksClient) {
        self.audible = audible; self.audnexus = audnexus; self.apple = apple
    }

    /// Audible's answers for a title (and author), then Apple's when Audible has none, or when the
    /// title alone gets nothing with the author attached.
    public func search(title: String, author: String?) async -> [AudiobookHit] {
        var hits = (try? await audible.search(title: title, author: author)) ?? []
        if hits.isEmpty, author != nil { hits = (try? await audible.search(title: title)) ?? [] }
        if hits.isEmpty { hits = (try? await apple.search([title, author].compactMap { $0 }.joined(separator: " "))) ?? [] }
        return hits
    }

    /// A chosen hit with Audnexus's description and genres folded in (an Audible hit only).
    public func details(_ hit: AudiobookHit) async -> AudiobookHit {
        guard let asin = hit.asin, let full = try? await audnexus.book(asin: asin) else { return hit }
        var out = hit
        if let s = full.summary, !s.isEmpty { out.summary = s }
        if out.genres.isEmpty { out.genres = full.genres }
        if out.coverURL == nil { out.coverURL = full.coverURL }
        if out.narrators.isEmpty { out.narrators = full.narrators }
        if out.series == nil { out.series = full.series; out.seriesPosition = full.seriesPosition }
        if out.year == nil { out.year = full.year }
        if out.runtimeMinutes == nil { out.runtimeMinutes = full.runtimeMinutes }
        return out
    }

    /// How well a hit answers for a book: the title's resemblance, and the author's when one is
    /// known. 1 is the same title by the same author.
    public static func score(_ hit: AudiobookHit, title: String, author: String?) -> Double {
        let t = MatchScorer.similarity(MatchScorer.normalise(title), MatchScorer.normalise(hit.title))
        // "Remnant Population: A Novel" against "Remnant Population": the catalogue's edition tail.
        let tStripped = MatchScorer.similarity(MatchScorer.normalise(title), MatchScorer.normalise(hit.title.components(separatedBy: ":").first ?? hit.title))
        let titleScore = max(t, tStripped)
        guard let author = author?.trimmingCharacters(in: .whitespaces), !author.isEmpty else { return titleScore }
        guard !hit.authors.isEmpty else { return titleScore * 0.9 }
        let wanted = author.replacingOccurrences(of: #"\s*(&|,|\band\b)\s*"#, with: "|", options: .regularExpression).split(separator: "|").map { MatchScorer.normalise(String($0)) }
        let have = hit.authors.map(MatchScorer.normalise)
        let authorScore = wanted.map { w in have.map { MatchScorer.similarity(w, $0) }.max() ?? 0 }.max() ?? 0
        return 0.7 * titleScore + 0.3 * authorScore
    }

    /// The hit to take without asking: the best one, when it is clearly the book.
    public static let acceptScore = 0.82
    public static func best(_ hits: [AudiobookHit], title: String, author: String?) -> AudiobookHit? {
        let scored = hits.map { ($0, score($0, title: title, author: author)) }.sorted { $0.1 > $1.1 }
        guard let top = scored.first, top.1 >= acceptScore else { return nil }
        return top.0
    }
}
