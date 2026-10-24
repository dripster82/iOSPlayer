import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenSubtitlesError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case missingLogin
    case http(Int, String?)
    case decoding(String)
    case offline

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No OpenSubtitles API key is set."
        case .missingLogin: "Downloading needs an OpenSubtitles account. Add the username and password in Settings."
        case .http(let code, let message):
            switch code {
            case 401: "OpenSubtitles rejected the login or key."
            case 406: "OpenSubtitles download limit reached for today."
            case 429: "OpenSubtitles is rate limiting; try again in a minute."
            default: "OpenSubtitles returned HTTP \(code)\(message.map { ": \($0)" } ?? "")."
            }
        case .decoding(let what): "Couldn't read OpenSubtitles' response for \(what)."
        case .offline: "OpenSubtitles is unreachable."
        }
    }
}

public struct SubtitleResult: Sendable, Identifiable, Hashable {
    public var id: String
    public var fileID: Int
    public var fileName: String
    public var language: String
    public var release: String
    public var downloads: Int
    public var hearingImpaired: Bool
    public var fromTrusted: Bool
    public var aiTranslated: Bool
    /// "Atlantis S03E03 1080p WEB" style text for a list row.
    public var summary: String {
        var tags: [String] = []
        if hearingImpaired { tags.append("SDH") }
        if fromTrusted { tags.append("trusted") }
        if aiTranslated { tags.append("AI translated") }
        return tags.isEmpty ? release : release + " · " + tags.joined(separator: ", ")
    }
}

/// OpenSubtitles REST API (api.opensubtitles.com/api/v1). Searching needs an API key; downloading
/// also needs a (free) account, because the download quota is per user. Attribution: "Subtitles
/// from OpenSubtitles.com". Nothing about the user's files is sent: only the TMDb id, season,
/// episode or title.
public actor OpenSubtitlesClient {
    public static let apiBase = URL(string: "https://api.opensubtitles.com/api/v1")!
    private let apiKey: String
    private let username: String?
    private let password: String?
    private let transport: HTTPTransport
    private let limiter: RateLimiter
    private var token: String?
    private let decoder = JSONDecoder()
    private let userAgent = "Reel v1.0"
    /// True when a username and password were given; downloading needs them, searching does not.
    nonisolated public let canDownload: Bool

    public init(apiKey: String, username: String? = nil, password: String? = nil, transport: HTTPTransport = URLSessionTransport(), limiter: RateLimiter = RateLimiter(limit: 5, window: 1)) {
        self.apiKey = apiKey
        self.username = (username?.isEmpty ?? true) ? nil : username
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.transport = transport
        self.limiter = limiter
        self.canDownload = self.username != nil && self.password != nil
    }

    /// Films search by their TMDb id; episodes by the show's TMDb id plus season and episode. `query`
    /// is the fallback when the item is unmatched. `languages` are ISO 639-1 codes ("en", "ja").
    public func search(tmdbID: Int? = nil, parentTMDbID: Int? = nil, season: Int? = nil, episode: Int? = nil, query: String? = nil, languages: [String]) async throws -> [SubtitleResult] {
        var items: [URLQueryItem] = [URLQueryItem(name: "languages", value: languages.map { $0.lowercased() }.sorted().joined(separator: ","))]
        if let parentTMDbID { items.append(URLQueryItem(name: "parent_tmdb_id", value: String(parentTMDbID))) }
        else if let tmdbID { items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbID))) }
        else if let query { items.append(URLQueryItem(name: "query", value: query)) }
        if let season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        items.append(URLQueryItem(name: "order_by", value: "download_count"))
        let page: SearchPage = try await request("subtitles", query: items, label: "subtitle search")
        return page.data.compactMap { d in
            guard let file = d.attributes.files.first else { return nil }
            return SubtitleResult(id: d.id, fileID: file.fileID, fileName: file.fileName ?? "subtitle.srt", language: d.attributes.language ?? "?",
                                  release: d.attributes.release ?? file.fileName ?? "", downloads: d.attributes.downloadCount ?? 0,
                                  hearingImpaired: d.attributes.hearingImpaired ?? false, fromTrusted: d.attributes.fromTrusted ?? false,
                                  aiTranslated: d.attributes.aiTranslated ?? false)
        }
    }

    /// Fetches the subtitle file's bytes (SRT or whatever the uploader provided).
    public func download(fileID: Int) async throws -> (data: Data, fileName: String) {
        guard canDownload else { throw OpenSubtitlesError.missingLogin }
        let token = try await ensureToken()
        var req = URLRequest(url: Self.apiBase.appendingPathComponent("download"))
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(["file_id": fileID])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let link: DownloadLink = try await send(req, label: "download link")
        guard let url = URL(string: link.link) else { throw OpenSubtitlesError.decoding("download link") }
        var fileReq = URLRequest(url: url)
        fileReq.timeoutInterval = 30
        do {
            let (data, response) = try await transport.data(for: fileReq)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw OpenSubtitlesError.http(http.statusCode, nil) }
            return (data, link.fileName ?? "subtitle.srt")
        } catch let e as OpenSubtitlesError { throw e } catch { throw OpenSubtitlesError.offline }
    }

    // MARK: - Plumbing

    private struct SearchPage: Decodable { var data: [Row] }
    private struct Row: Decodable { var id: String; var attributes: Attributes }
    private struct Attributes: Decodable {
        var language: String?
        var release: String?
        var downloadCount: Int?
        var hearingImpaired: Bool?
        var fromTrusted: Bool?
        var aiTranslated: Bool?
        var files: [File]
        enum CodingKeys: String, CodingKey {
            case language, release, files
            case downloadCount = "download_count", hearingImpaired = "hearing_impaired", fromTrusted = "from_trusted", aiTranslated = "ai_translated"
        }
    }
    private struct File: Decodable {
        var fileID: Int; var fileName: String?
        enum CodingKeys: String, CodingKey { case fileID = "file_id", fileName = "file_name" }
    }
    private struct LoginResponse: Decodable { var token: String }
    private struct DownloadLink: Decodable {
        var link: String; var fileName: String?
        enum CodingKeys: String, CodingKey { case link, fileName = "file_name" }
    }
    private struct ErrorBody: Decodable { var message: String? }

    private func ensureToken() async throws -> String {
        if let token { return token }
        guard let username, let password else { throw OpenSubtitlesError.missingLogin }
        var req = URLRequest(url: Self.apiBase.appendingPathComponent("login"))
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let login: LoginResponse = try await send(req, label: "login")
        token = login.token
        return login.token
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem], label: String) async throws -> T {
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        return try await send(URLRequest(url: comps.url!), label: label)
    }

    private func send<T: Decodable>(_ request: URLRequest, label: String) async throws -> T {
        guard !apiKey.isEmpty else { throw OpenSubtitlesError.missingAPIKey }
        var req = request
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        await limiter.acquire()
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: req) } catch { throw OpenSubtitlesError.offline }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 { token = nil }
            throw OpenSubtitlesError.http(http.statusCode, (try? decoder.decode(ErrorBody.self, from: data))?.message)
        }
        do { return try decoder.decode(T.self, from: data) } catch { throw OpenSubtitlesError.decoding(label) }
    }
}
