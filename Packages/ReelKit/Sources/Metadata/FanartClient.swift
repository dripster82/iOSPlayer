import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Extra artwork fanart.tv holds that TMDb does not: transparent logos, clear art and
/// alternative backgrounds. Optional, keyed; nothing breaks without it. Attribution: "Artwork
/// from fanart.tv".
public struct FanartArt: Sendable, Hashable {
    public var logoURL: String?
    public var clearArtURL: String?
    public var backgroundURLs: [String]
    /// Every candidate, for the artwork picker (the single fields above are the automatic choice).
    public var logoURLs: [String] = []
    public var posterURLs: [String] = []
    public init(logoURL: String? = nil, clearArtURL: String? = nil, backgroundURLs: [String] = [], logoURLs: [String] = [], posterURLs: [String] = []) {
        self.logoURL = logoURL; self.clearArtURL = clearArtURL; self.backgroundURLs = backgroundURLs; self.logoURLs = logoURLs; self.posterURLs = posterURLs
    }
    public var isEmpty: Bool { logoURL == nil && clearArtURL == nil && backgroundURLs.isEmpty }
}

public enum FanartError: Error, LocalizedError, Sendable {
    case missingAPIKey, http(Int), decoding, offline
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No fanart.tv API key is set."
        case .http(404): "fanart.tv has no artwork for this title."
        case .http(let c): "fanart.tv returned HTTP \(c)."
        case .decoding: "Couldn't read fanart.tv's response."
        case .offline: "fanart.tv is unreachable."
        }
    }
}

public actor FanartClient {
    public static let apiBase = URL(string: "https://webservice.fanart.tv/v3")!
    private let apiKey: String
    /// The user's own personal key, sent as `client_key` alongside the project key, as fanart.tv's
    /// terms require ("this should be sent in addition to your project key"). Earns the user faster
    /// access to newly approved images.
    private let clientKey: String?
    private let language: String
    private let transport: HTTPTransport
    private let cache: MetadataCache
    private let decoder = JSONDecoder()

    public init(apiKey: String, clientKey: String? = nil, language: String = "en", transport: HTTPTransport = URLSessionTransport(), cache: MetadataCache = MetadataCache()) {
        self.apiKey = apiKey
        self.clientKey = clientKey.flatMap { $0.isEmpty ? nil : $0 }
        self.language = String(language.prefix(2)).lowercased()
        self.transport = transport
        self.cache = cache
    }

    /// Shows are keyed by TheTVDB id (fanart.tv's convention), which TMDb's external ids supply.
    public func show(tvdbID: Int) async throws -> FanartArt {
        let r: ShowResponse = try await get("tv/\(tvdbID)")
        return FanartArt(logoURL: pick(r.hdtvlogo, r.clearlogo), clearArtURL: pick(r.hdclearart, r.clearart), backgroundURLs: all(r.showbackground),
                         logoURLs: all(r.hdtvlogo, limit: 10) + all(r.clearlogo, limit: 10), posterURLs: all(r.tvposter, limit: 10))
    }

    public func movie(tmdbID: Int) async throws -> FanartArt {
        let r: MovieResponse = try await get("movies/\(tmdbID)")
        return FanartArt(logoURL: pick(r.hdmovielogo, r.movielogo), clearArtURL: pick(r.hdmovieclearart, r.movieart), backgroundURLs: all(r.moviebackground),
                         logoURLs: all(r.hdmovielogo, limit: 10) + all(r.movielogo, limit: 10), posterURLs: all(r.movieposter, limit: 10))
    }

    // MARK: - Plumbing

    struct Image: Decodable { var url: String; var lang: String?; var likes: String? }
    private struct ShowResponse: Decodable {
        var hdtvlogo: [Image]?; var clearlogo: [Image]?; var hdclearart: [Image]?; var clearart: [Image]?; var showbackground: [Image]?; var tvposter: [Image]?
    }
    private struct MovieResponse: Decodable {
        var hdmovielogo: [Image]?; var movielogo: [Image]?; var hdmovieclearart: [Image]?; var movieart: [Image]?; var moviebackground: [Image]?; var movieposter: [Image]?
    }

    /// The most liked image in the user's language, else a language-neutral one ("00"), else any;
    /// HD sets first.
    private func pick(_ sets: [Image]?...) -> String? {
        for set in sets {
            guard let set, !set.isEmpty else { continue }
            let sorted = set.sorted { (Int($0.likes ?? "") ?? 0) > (Int($1.likes ?? "") ?? 0) }
            if let mine = sorted.first(where: { $0.lang == language }) { return mine.url }
            if let neutral = sorted.first(where: { $0.lang == "00" || $0.lang == nil || $0.lang == "" }) { return neutral.url }
            return sorted.first?.url
        }
        return nil
    }
    private func all(_ set: [Image]?, limit: Int = 5) -> [String] {
        (set ?? []).sorted { (Int($0.likes ?? "") ?? 0) > (Int($1.likes ?? "") ?? 0) }.prefix(limit).map(\.url)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard !apiKey.isEmpty else { throw FanartError.missingAPIKey }
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + (clientKey.map { [URLQueryItem(name: "client_key", value: $0)] } ?? [])
        let url = comps.url!
        let cacheKey = "fanart:" + path
        if let entry = await cache.read(cacheKey), entry.isFresh { return try decode(entry.data) }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        do {
            let (data, response) = try await transport.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw FanartError.http(http.statusCode) }
            let value: T = try decode(data)
            await cache.write(cacheKey, data: data)
            return value
        } catch let e as FanartError { throw e } catch {
            if let entry = await cache.read(cacheKey) { return try decode(entry.data) }
            throw FanartError.offline
        }
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw FanartError.decoding }
    }
}
