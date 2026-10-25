#if canImport(Network)
import Foundation
import Network
import MediaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A DLNA / UPnP media server (MiniDLNA, Synology Media Server, Plex's DLNA, Jellyfin, Emby,
/// Serviio, Twonky): read-only browsing through its ContentDirectory service and playback from
/// the HTTP URLs it hands out, which VLC and Apple's player both read directly.
///
/// The server's description document is found by a unicast SSDP search to the host (a multicast
/// search needs an entitlement Apple grants case by case), by the well-known locations the common
/// servers use, or from a description URL the user pastes in. The library sees the server's
/// containers as folders and its video items as files, with paths made of their titles, so the
/// file-name parser gets "Show/Season 1/Episode.mkv" as it would from a share.
public actor DLNASource: MediaSource {
    public let config: SourceConfig
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Reel/0.1 UPnP/1.0"]
        return URLSession(configuration: c)
    }()
    /// Where to send Browse requests, once the description has been read.
    private var controlURL: URL?
    private var serviceType = "urn:schemas-upnp-org:service:ContentDirectory:1"
    /// Library path → the server's object, filled as folders are listed.
    private var objects: [String: UPnPObject] = [:]
    /// The container the library treats as the root: the server's real folder tree when it offers
    /// one, so "All Video", "By Date" and the other views don't list every file three times over.
    private var rootID = "0"

    public init(config: SourceConfig) { self.config = config }

    public func connect(credentials: Credentials?) async throws {
        let description = try await locateDescription()
        let (data, _) = try await get(description)
        guard let service = DeviceDescription.parse(data, base: description) else {
            Diagnostics.log("source", "dlna \(config.host): no ContentDirectory service in \(description)")
            throw SourceError.unsupported("This server's media directory")
        }
        controlURL = service.controlURL
        serviceType = service.serviceType
        rootID = try await findFolderTree()
        Diagnostics.log("source", "dlna \(config.host): \(service.friendlyName) at \(service.controlURL), root \(rootID)")
        _ = try await list("")
    }

    /// MiniDLNA, Serviio and Synology put the real folders under Video → Folders; Plex and Jellyfin
    /// list libraries at the root. The first shape is cut down to its folder tree.
    private func findFolderTree() async throws -> String {
        let root = try await browseChildren(of: "0")
        func named(_ list: [UPnPObject], _ names: [String]) -> UPnPObject? { list.first { $0.isContainer && names.contains($0.title.lowercased()) } }
        guard let video = named(root, ["video", "videos", "movies & tv"]) else { return "0" }
        let inside = try await browseChildren(of: video.id)
        if let folders = named(inside, ["folders", "folder", "by folder"]) { return folders.id }
        return video.id
    }

    public func list(_ relativePath: String) async throws -> [DirectoryEntry] {
        let id = try await objectID(for: relativePath)
        let children = try await browseChildren(of: id)
        var seen: Set<String> = []
        var out: [DirectoryEntry] = []
        for child in children {
            guard child.isContainer || child.isVideo else { continue }
            var name = child.fileName
            // Two items with the same title would share a path; the second gets a suffix so each keeps its own.
            var n = 2
            while seen.contains(name.lowercased()) { name = child.fileName(suffix: " (\(n))"); n += 1 }
            seen.insert(name.lowercased())
            let rel = relativePath.isEmpty ? name : relativePath + "/" + name
            objects[rel] = child
            out.append(DirectoryEntry(name: name, relativePath: rel, isDirectory: child.isContainer, size: child.size, modified: child.date))
        }
        return out.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        let object = try await object(for: relativePath)
        return DirectoryEntry(name: (relativePath as NSString).lastPathComponent, relativePath: relativePath, isDirectory: object.isContainer, size: object.size, modified: object.date)
    }

    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL {
        guard let url = try await object(for: relativePath).resource else { throw SourceError.notFound(relativePath) }
        return url
    }

    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        let url = try await playbackURL(relativePath, credentials: nil)
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw SourceError.notFound(relativePath) }
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
        let url = try await playbackURL(relativePath, credentials: nil)
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else { throw SourceError.notFound(relativePath) }
        if http.statusCode == 200, data.count > length || offset > 0 {
            let start = Int(min(Int64(data.count), offset))
            return data.subdata(in: start..<min(data.count, start + length))
        }
        return data
    }

    public func disconnect() async { controlURL = nil }

    // MARK: - Finding the server

    /// Candidate description documents: the URL the user gave, the answer to a unicast SSDP search,
    /// then the places the usual servers keep theirs.
    private func locateDescription() async throws -> URL {
        if let given = URL(string: config.path), given.scheme?.hasPrefix("http") == true { return given }
        if let found = await ssdpSearch() { return found }
        let host = config.host
        var candidates: [String] = []
        if let p = config.port { candidates.append("http://\(host):\(p)/") }
        candidates += [
            "http://\(host):8200/rootDesc.xml",              // MiniDLNA / ReadyMedia
            "http://\(host):50001/desc/device.xml",         // Synology Media Server
            "http://\(host):32469/DeviceDescription.xml",   // Plex
            "http://\(host):8096/dlna/description.xml",     // Jellyfin, Emby (also 8920 for HTTPS)
            "http://\(host):8895/deviceDescription",        // Serviio
            "http://\(host):9000/DeviceDescription.xml",    // Twonky
            "http://\(host):2869/upnphost/udhisapi.dll?content=uuid:",   // Windows Media Player (needs the uuid; a 404 is fine)
            "http://\(host):1900/",
        ]
        for c in candidates {
            guard let url = URL(string: c) else { continue }
            if let (data, http) = try? await get(url), (200..<300).contains(http.statusCode), DeviceDescription.parse(data, base: url) != nil { return url }
        }
        Diagnostics.log("source", "dlna \(host): no description found")
        throw SourceError.unreachable(host)
    }

    /// M-SEARCH sent straight to the host's SSDP port. Most servers answer a unicast search.
    private func ssdpSearch() async -> URL? {
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: 1900, using: .udp)
        defer { connection.cancel() }
        do {
            try await FTPControl.ready(connection, timeout: 5)
            try await withTimeout(5, onTimeout: { connection.cancel() }) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { e in if let e { cont.resume(throwing: e) } else { cont.resume() } })
                }
            }
            let (data, _) = try await FTPControl.receive(connection, timeout: 4)
            return SSDP.location(in: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    // MARK: - ContentDirectory

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { throw SourceError.unreachable(config.host) }
            return (data, http)
        } catch let e as SourceError { throw e }
        catch { throw SourceError.unreachable(config.host) }
    }

    /// Browse, paged, until the server has no more children.
    private func browseChildren(of id: String) async throws -> [UPnPObject] {
        var out: [UPnPObject] = []
        var start = 0
        while true {
            let page = try await browse(id, flag: "BrowseDirectChildren", start: start, count: 500)
            out += page.objects
            start += page.objects.count
            if page.objects.isEmpty || start >= page.total || page.total == 0 { break }
        }
        return out
    }

    private func browse(_ id: String, flag: String, start: Int, count: Int) async throws -> (objects: [UPnPObject], total: Int) {
        guard let controlURL else { throw SourceError.unreachable(config.host) }
        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(serviceType)#Browse\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Browse xmlns:u="\(serviceType)"><ObjectID>\(DIDL.escape(id))</ObjectID><BrowseFlag>\(flag)</BrowseFlag><Filter>*</Filter><StartingIndex>\(start)</StartingIndex><RequestedCount>\(count)</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>
        """.utf8)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw SourceError.unreachable(config.host) }
        guard let http = resp as? HTTPURLResponse else { throw SourceError.unreachable(config.host) }
        guard http.statusCode == 200 else {
            Diagnostics.log("source", "dlna \(config.host): Browse \(id) → HTTP \(http.statusCode)")
            throw http.statusCode == 401 ? SourceError.authFailed : SourceError.notFound(id)
        }
        let result = DIDL.browseResult(data)
        return (DIDL.parse(result.didl), result.total)
    }

    /// The server's object for a library path, walking down from the root by title when it has
    /// not been listed in this session (after a relaunch, say).
    private func object(for relativePath: String) async throws -> UPnPObject {
        if let o = objects[relativePath] { return o }
        guard !relativePath.isEmpty else { return UPnPObject(id: rootID, parentID: "-1", title: "", isContainer: true) }
        let parent = (relativePath as NSString).deletingLastPathComponent
        _ = try await list(parent)
        guard let o = objects[relativePath] else { throw SourceError.notFound(relativePath) }
        return o
    }

    private func objectID(for relativePath: String) async throws -> String {
        relativePath.isEmpty ? rootID : try await object(for: relativePath).id
    }
}

// MARK: - UPnP pieces

/// One entry from a ContentDirectory Browse.
public struct UPnPObject: Hashable, Sendable {
    public var id: String
    public var parentID: String
    public var title: String
    public var isContainer: Bool
    public var upnpClass = ""
    public var resource: URL?
    public var mimeType: String?
    public var size: Int64?
    public var date: Date?

    public init(id: String, parentID: String, title: String, isContainer: Bool, upnpClass: String = "", resource: URL? = nil, mimeType: String? = nil, size: Int64? = nil, date: Date? = nil) {
        self.id = id; self.parentID = parentID; self.title = title; self.isContainer = isContainer; self.upnpClass = upnpClass
        self.resource = resource; self.mimeType = mimeType; self.size = size; self.date = date
    }

    public var isVideo: Bool {
        if upnpClass.hasPrefix("object.item.videoItem") { return true }
        if let m = mimeType, m.hasPrefix("video/") { return true }
        return VideoFile.videoExtensions.contains(fileExtension)
    }

    /// From the resource URL, else the MIME type; "mkv" for the Matroska types servers label oddly.
    public var fileExtension: String {
        if let ext = resource?.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 4 { return ext }
        switch mimeType?.lowercased() {
        case "video/x-matroska", "video/mkv": return "mkv"
        case "video/mp4": return "mp4"
        case "video/x-msvideo", "video/avi": return "avi"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "video/mp2t", "video/vnd.dlna.mpeg-tts": return "ts"
        case "video/x-ms-wmv": return "wmv"
        case "video/webm": return "webm"
        default: return isContainer ? "" : "mkv"
        }
    }

    /// The title as a file name: slashes removed, the extension added when the title lacks it.
    public var fileName: String { fileName(suffix: "") }
    public func fileName(suffix: String) -> String {
        let clean = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        if isContainer { return (clean.isEmpty ? id : clean) + suffix }
        let ext = fileExtension
        let base = clean.lowercased().hasSuffix("." + ext) ? String(clean.dropLast(ext.count + 1)) : clean
        return (base.isEmpty ? id : base) + suffix + (ext.isEmpty ? "" : "." + ext)
    }
}

/// The ContentDirectory service of a device description.
public struct DeviceDescription: Sendable {
    public var friendlyName: String
    public var serviceType: String
    public var controlURL: URL

    /// Finds the ContentDirectory service in a description document (root or embedded device).
    public static func parse(_ data: Data, base: URL) -> DeviceDescription? {
        let p = DescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else { return nil }
        guard let service = p.services.first(where: { $0.type.contains("ContentDirectory") }) else { return nil }
        let root = p.urlBase.flatMap(URL.init(string:)) ?? base
        guard let control = URL(string: service.control, relativeTo: root)?.absoluteURL else { return nil }
        return DeviceDescription(friendlyName: p.friendlyName, serviceType: service.type, controlURL: control)
    }

    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var friendlyName = ""
        var urlBase: String?
        var services: [(type: String, control: String)] = []
        private var text = ""
        private var currentType = "", currentControl = ""
        private var inService = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            if name == "service" { inService = true; currentType = ""; currentControl = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "friendlyName": if friendlyName.isEmpty { friendlyName = value }
            case "URLBase": urlBase = value
            case "serviceType" where inService: currentType = value
            case "controlURL" where inService: currentControl = value
            case "service": inService = false; services.append((currentType, currentControl))
            default: break
            }
        }
    }
}

public enum SSDP {
    /// The LOCATION header of an SSDP response.
    public static func location(in response: String) -> URL? {
        for line in response.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            return URL(string: parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// DIDL-Lite, the XML a Browse answers with (inside the SOAP envelope, escaped).
public enum DIDL {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The Result text (already unescaped by the XML parser) and TotalMatches of a Browse response.
    public static func browseResult(_ data: Data) -> (didl: String, total: Int) {
        let p = EnvelopeParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return (p.result, p.total)
    }

    private final class EnvelopeParser: NSObject, XMLParserDelegate {
        var result = "", total = 0
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { text = "" }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Result" { result = text }
            if name == "TotalMatches" { total = Int(text.trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
    }

    public static func parse(_ didl: String) -> [UPnPObject] {
        let p = DIDLParser()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.delegate = p
        parser.parse()
        return p.objects
    }

    private final class DIDLParser: NSObject, XMLParserDelegate {
        var objects: [UPnPObject] = []
        private var current: UPnPObject?
        private var text = ""
        private var resAttributes: [String: String] = [:]
        private var bestResRank = -1
        private static let dateFormats: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"].map { f in
            let d = DateFormatter(); d.dateFormat = f; d.timeZone = TimeZone(identifier: "UTC"); d.locale = Locale(identifier: "en_US_POSIX"); return d
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "container", "item":
                current = UPnPObject(id: attributes["id"] ?? "", parentID: attributes["parentID"] ?? "", title: "", isContainer: local == "container")
                bestResRank = -1
            case "res": resAttributes = attributes
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current != nil else { return }
            switch local {
            case "title": current?.title = value
            case "class": current?.upnpClass = value
            case "date": current?.date = Self.dateFormats.lazy.compactMap { $0.date(from: String(value.prefix(19))) }.first
            case "res":
                // Prefer the original file over transcoded or thumbnail renditions: http-get with a video type, biggest size.
                let info = (resAttributes["protocolInfo"] ?? "").split(separator: ":").map(String.init)
                let mime = info.count > 2 ? info[2] : ""
                var rank = 0
                if info.first == "http-get" { rank += 1 }
                if mime.hasPrefix("video/") { rank += 2 }
                if (resAttributes["size"].flatMap(Int64.init) ?? 0) > (current?.size ?? 0) { rank += 1 }
                if rank > bestResRank, let url = URL(string: value) {
                    bestResRank = rank
                    current?.resource = url
                    current?.mimeType = mime.isEmpty ? nil : mime
                    current?.size = resAttributes["size"].flatMap(Int64.init)
                }
            case "container", "item":
                if let c = current { objects.append(c) }
                current = nil
            default: break
            }
        }
    }
}
#endif
