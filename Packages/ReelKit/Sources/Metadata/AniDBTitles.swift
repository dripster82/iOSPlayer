import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Offline anime title index built from AniDB's daily titles dump (anime-titles.xml.gz).
///
/// No API key and no per-title requests: AniDB publishes the dump for exactly this use, asks for at
/// most one download per day, and forbids hammering its HTTP API. Every main, official and synonym
/// title is indexed under `MatchScorer.normalise`, so "hataraku saibou black" finds the same entry as
/// "Cells at Work! CODE BLACK". The parsed index is cached as JSON next to the metadata cache.
public actor AniDBTitles {
    public static let dumpURL = URL(string: "https://anidb.net/api/anime-titles.xml.gz")!
    public static let refreshInterval: TimeInterval = 7 * 24 * 3600

    public struct Hit: Sendable, Hashable {
        public var aid: Int
        public var title: String
    }

    /// Normalised title → AniDB ids, plus each id's main title for display.
    struct Index: Codable {
        var titles: [String: [Int]]
        var mainTitles: [Int: String]
        var builtAt: Date
    }

    private let indexURL: URL
    private let sourceURL: URL
    private let transport: HTTPTransport
    private var index: Index?
    private var loadAttempted = false

    public init(directory: URL? = nil, sourceURL: URL = AniDBTitles.dumpURL, transport: HTTPTransport = URLSessionTransport()) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        indexURL = base.appendingPathComponent("anidb-titles.json")
        self.sourceURL = sourceURL
        self.transport = transport
    }

    /// Exact matches (after normalisation) for a title. Empty when the index is unavailable.
    public func lookup(_ title: String) async -> [Hit] {
        await ensureLoaded()
        guard let index else { return [] }
        let key = MatchScorer.normalise(title)
        guard !key.isEmpty, let aids = index.titles[key] else { return [] }
        return aids.map { Hit(aid: $0, title: index.mainTitles[$0] ?? title) }
    }

    public var isAvailable: Bool { get async { await ensureLoaded(); return index != nil } }

    // MARK: - Loading

    private func ensureLoaded() async {
        if index != nil, let built = index?.builtAt, Date().timeIntervalSince(built) < Self.refreshInterval { return }
        if index == nil, let data = try? Data(contentsOf: indexURL), let cached = try? JSONDecoder().decode(Index.self, from: data) {
            index = cached
            if Date().timeIntervalSince(cached.builtAt) < Self.refreshInterval { return }
        }
        guard !loadAttempted else { return }   // one download attempt per process
        loadAttempted = true
        var request = URLRequest(url: sourceURL)
        request.setValue("Reel/0.1 (iOS media player; anime title matching)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        guard let (data, response) = try? await transport.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let xml = try? Gunzip.decompress(data) else { return }
        let built = Self.parse(xml: xml)
        guard !built.titles.isEmpty else { return }
        index = built
        if let encoded = try? JSONEncoder().encode(built) { try? encoded.write(to: indexURL, options: .atomic) }
    }

    /// Parses the dump. Internal so tests can feed a small fixture.
    static func parse(xml: Data) -> Index {
        let delegate = TitlesParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return Index(titles: delegate.titles, mainTitles: delegate.mainTitles, builtAt: Date())
    }

    private final class TitlesParser: NSObject, XMLParserDelegate {
        var titles: [String: [Int]] = [:]
        var mainTitles: [Int: String] = [:]
        private var aid = 0
        private var type = ""
        private var text = ""
        private var inTitle = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "anime": aid = Int(attributes["aid"] ?? "") ?? 0
            case "title": type = attributes["type"] ?? ""; text = ""; inTitle = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "title", inTitle else { return }
            inTitle = false
            guard aid > 0, ["main", "official", "syn"].contains(type) else { return }
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "main" { mainTitles[aid] = title }
            let key = MatchScorer.normalise(title)
            guard !key.isEmpty else { return }
            if titles[key]?.contains(aid) != true { titles[key, default: []].append(aid) }
        }
    }
}
