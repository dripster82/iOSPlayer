import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anime-Lists (github.com/Anime-Lists/anime-lists): the community mapping from AniDB entries to
/// TheTVDB/TMDb shows, seasons and episode offsets. This is how Plex's HAMA agent and Jellyfin turn
/// "Sword Art Online: Alicization - War of Underworld (2020) - 03" into Sword Art Online S04E15.
/// Public file, no key. Refreshed weekly.
public actor AnimeLists {
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/Anime-Lists/anime-lists/master/anime-list-full.xml")!
    public static let refreshInterval: TimeInterval = 7 * 24 * 3600

    public struct Mapping: Codable, Sendable {
        public var anidbSeason: Int
        public var tvdbSeason: Int
        public var tmdbSeason: Int?
        public var start: Int?
        public var end: Int?
        public var offset: Int
        /// Explicit AniDB episode → target episode pairs from ";1-26;2-27;".
        public var pairs: [Int: Int]
    }

    public struct Entry: Codable, Sendable {
        public var anidbID: Int
        public var name: String
        public var tvdbID: String?
        public var tmdbTV: Int?
        public var tmdbMovie: Int?
        /// "1", "2", … or "a" (absolute numbering).
        public var defaultTVDBSeason: String?
        public var tmdbSeason: String?
        public var episodeOffset: Int
        public var tmdbOffset: Int?
        public var mappings: [Mapping]

        public struct Target: Sendable, Equatable {
            public var tmdbShow: Int
            public var season: Int
            public var episode: Int
        }

        /// Where an AniDB episode lives on TMDb. `anidbSeason` is 1 for regular episodes, 0 for specials/OVAs.
        public func resolve(anidbSeason: Int, episode: Int) -> Target? {
            guard let tmdbShow = tmdbTV else { return nil }
            for m in mappings where m.anidbSeason == anidbSeason {
                let season = m.tmdbSeason ?? m.tvdbSeason
                if let e = m.pairs[episode] { return Target(tmdbShow: tmdbShow, season: season, episode: e) }
                if let s = m.start, let en = m.end {
                    if (s...en).contains(episode) { return Target(tmdbShow: tmdbShow, season: season, episode: episode + m.offset) }
                } else if m.pairs.isEmpty {
                    return Target(tmdbShow: tmdbShow, season: season, episode: episode + m.offset)
                }
            }
            if anidbSeason == 0 { return Target(tmdbShow: tmdbShow, season: 0, episode: episode) }
            let seasonText = tmdbSeason ?? defaultTVDBSeason ?? "1"
            // "a" = absolute numbering; TMDb has no absolute order, season 1 is the best available guess.
            let season = Int(seasonText) ?? 1
            return Target(tmdbShow: tmdbShow, season: season, episode: episode + (tmdbOffset ?? episodeOffset))
        }
    }

    struct Index: Codable {
        var entries: [Int: Entry]
        var builtAt: Date
    }

    private let indexURL: URL
    private let sourceURL: URL
    private let transport: HTTPTransport
    private var index: Index?
    private var loadAttempted = false

    public init(directory: URL? = nil, sourceURL: URL = AnimeLists.sourceURL, transport: HTTPTransport = URLSessionTransport()) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        indexURL = base.appendingPathComponent("anime-lists.json")
        self.sourceURL = sourceURL
        self.transport = transport
    }

    public func entry(forAniDB aid: Int) async -> Entry? {
        await ensureLoaded()
        return index?.entries[aid]
    }

    private func ensureLoaded() async {
        if let built = index?.builtAt, Date().timeIntervalSince(built) < Self.refreshInterval { return }
        if index == nil, let data = try? Data(contentsOf: indexURL), let cached = try? JSONDecoder().decode(Index.self, from: data) {
            index = cached
            if Date().timeIntervalSince(cached.builtAt) < Self.refreshInterval { return }
        }
        guard !loadAttempted else { return }
        loadAttempted = true
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 60
        guard let (data, response) = try? await transport.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return }
        let entries = Self.parse(xml: data)
        guard !entries.isEmpty else { return }
        index = Index(entries: entries, builtAt: Date())
        if let encoded = try? JSONEncoder().encode(index) { try? encoded.write(to: indexURL, options: .atomic) }
    }

    static func parse(xml: Data) -> [Int: Entry] {
        let delegate = ListParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private final class ListParser: NSObject, XMLParserDelegate {
        var entries: [Int: Entry] = [:]
        private var current: Entry?
        private var mapping: Mapping?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            text = ""
            switch name {
            case "anime":
                guard let aid = Int(a["anidbid"] ?? "") else { current = nil; return }
                current = Entry(anidbID: aid, name: "", tvdbID: a["tvdbid"], tmdbTV: Int(a["tmdbtv"] ?? ""), tmdbMovie: Int(a["tmdbid"] ?? ""),
                                defaultTVDBSeason: a["defaulttvdbseason"], tmdbSeason: a["tmdbseason"],
                                episodeOffset: Int(a["episodeoffset"] ?? "") ?? 0, tmdbOffset: Int(a["tmdboffset"] ?? ""), mappings: [])
            case "mapping":
                mapping = Mapping(anidbSeason: Int(a["anidbseason"] ?? "") ?? 1, tvdbSeason: Int(a["tvdbseason"] ?? "") ?? 1,
                                  tmdbSeason: Int(a["tmdbseason"] ?? ""), start: Int(a["start"] ?? ""), end: Int(a["end"] ?? ""),
                                  offset: Int(a["offset"] ?? "") ?? 0, pairs: [:])
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "name": current?.name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "mapping":
                guard var m = mapping else { return }
                // ";1-26;2-27;" → [1: 26, 2: 27]
                for pair in text.split(separator: ";") {
                    let parts = pair.split(separator: "-", maxSplits: 1)
                    if parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]) { m.pairs[from] = to }
                }
                current?.mappings.append(m)
                mapping = nil
            case "anime":
                if let e = current { entries[e.anidbID] = e }
                current = nil
            default: break
            }
        }
    }
}
