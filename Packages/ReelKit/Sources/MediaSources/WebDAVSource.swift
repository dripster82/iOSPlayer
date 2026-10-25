import Foundation
import MediaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin WebDAV client: PROPFIND for listing, HEAD for stat, authenticated URL for VLC.
/// Small enough to own rather than depend on a library.
public actor WebDAVSource: MediaSource {
    public let config: SourceConfig
    private var credentials: Credentials?
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Reel/0.1"]
        return URLSession(configuration: c)
    }()

    public init(config: SourceConfig) { self.config = config }

    private var baseURL: URL {
        var c = URLComponents()
        c.scheme = config.useTLS ? "https" : "http"
        c.host = config.host
        c.port = config.port
        c.path = config.path.hasPrefix("/") ? config.path : "/" + config.path
        if !c.path.hasSuffix("/") { c.path += "/" }
        return c.url!
    }

    public func connect(credentials: Credentials?) async throws {
        self.credentials = credentials
        _ = try await list("")
    }

    public func list(_ relativePath: String) async throws -> [DirectoryEntry] {
        let url = resolve(relativePath, directory: true)
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("""
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:displayname/></d:prop></d:propfind>
        """.utf8)
        authorise(&req)
        let (data, response) = try await perform(req)
        guard (200..<300).contains(response.statusCode) else { throw map(response.statusCode, relativePath) }
        let parser = PropfindParser(basePath: url.path)
        return parser.parse(data).map { item in
            let rel = relativePath.isEmpty ? item.name : relativePath + "/" + item.name
            return DirectoryEntry(name: item.name, relativePath: rel, isDirectory: item.isDirectory, size: item.size, modified: item.modified)
        }.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        var req = URLRequest(url: resolve(relativePath, directory: false))
        req.httpMethod = "HEAD"
        authorise(&req)
        let (_, response) = try await perform(req)
        guard (200..<300).contains(response.statusCode) else { throw map(response.statusCode, relativePath) }
        let size = (response.value(forHTTPHeaderField: "Content-Length")).flatMap(Int64.init)
        let modified = response.value(forHTTPHeaderField: "Last-Modified").flatMap(PropfindParser.httpDate.date(from:))
        return DirectoryEntry(name: (relativePath as NSString).lastPathComponent, relativePath: relativePath, isDirectory: false, size: size, modified: modified)
    }

    /// VLC handles HTTP range requests itself. Basic auth is embedded in the URL for the
    /// lifetime of playback only; the caller must not store the result.
    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL {
        var c = URLComponents(url: resolve(relativePath, directory: false), resolvingAgainstBaseURL: false)!
        if let creds = credentials ?? self.credentials {
            c.user = creds.username
            c.password = creds.password
        }
        return c.url!
    }

    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        var req = URLRequest(url: resolve(relativePath, directory: false))
        authorise(&req)
        req.timeoutInterval = 60
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw SourceError.unreachable(config.host) }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authFailed }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.notFound(relativePath) }
        let total = http.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if !progress(written, total) { throw CancellationError() }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        _ = progress(written, total > 0 ? total : written)
    }

    public func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        var req = URLRequest(url: resolve(relativePath, directory: false))
        authorise(&req)
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SourceError.unreachable(config.host) }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authFailed }
        guard http.statusCode == 206 || http.statusCode == 200 else { throw SourceError.notFound(relativePath) }
        // A server that ignored the range sent the whole file: cut the window out.
        if http.statusCode == 200, data.count > length || offset > 0 {
            let start = Int(min(Int64(data.count), offset))
            return data.subdata(in: start..<min(data.count, start + length))
        }
        return data
    }

    public func disconnect() async { credentials = nil }

    // MARK: -

    private func resolve(_ relativePath: String, directory: Bool) -> URL {
        var url = baseURL
        for part in relativePath.split(separator: "/") { url.appendPathComponent(String(part)) }
        if directory && !relativePath.isEmpty { url.appendPathComponent("") }
        return url
    }

    private func authorise(_ req: inout URLRequest) {
        guard let creds = credentials else { return }
        let token = Data("\(creds.username):\(creds.password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withRetries {
            do {
                let (data, resp) = try await self.session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw SourceError.unreachable(self.config.host) }
                if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authFailed }
                return (data, http)
            } catch let e as SourceError { Diagnostics.log("source", "webdav \(self.config.host): \(e)"); throw e }
            catch { Diagnostics.log("source", "webdav \(self.config.host): \(error.localizedDescription)"); throw SourceError.unreachable(self.config.host) }
        }
    }

    private func map(_ status: Int, _ path: String) -> SourceError {
        switch status {
        case 401, 403: .authFailed
        case 404: .notFound(path)
        default: .unreachable(config.host)
        }
    }
}

/// Parses a Depth:1 PROPFIND multistatus body. Skips the entry for the folder itself.
final class PropfindParser: NSObject, XMLParserDelegate {
    struct Item { var name: String; var isDirectory: Bool; var size: Int64?; var modified: Date? }

    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private let basePath: String
    private var items: [Item] = []
    private var href = "", size = "", modified = "", display = ""
    private var isCollection = false
    private var text = ""

    init(basePath: String) { self.basePath = basePath.removingPercentEncoding ?? basePath }

    func parse(_ data: Data) -> [Item] {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch name {
        case "response": href = ""; size = ""; modified = ""; display = ""; isCollection = false
        case "collection": isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "href": href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getcontentlength": size = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getlastmodified": modified = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "displayname": display = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "response":
            let path = (href.removingPercentEncoding ?? href)
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let baseTrimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            // Skip the directory itself.
            guard trimmed != baseTrimmed, !trimmed.isEmpty else { return }
            let name = display.isEmpty ? (trimmed as NSString).lastPathComponent : display
            items.append(Item(name: name, isDirectory: isCollection, size: Int64(size), modified: Self.httpDate.date(from: modified)))
        default: break
        }
    }
}
