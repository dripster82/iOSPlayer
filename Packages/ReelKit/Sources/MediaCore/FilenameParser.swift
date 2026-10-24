import Foundation

/// Result of parsing a relative path into the parts the matcher needs.
public struct ParsedName: Equatable, Sendable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    /// Second episode in a double-episode file like S01E01E02 or S01E01-02.
    public var episodeEnd: Int?
    public var quality: [String]
    /// Title of the show folder when the file sits under `Show/Season N/`.
    public var folderTitle: String?

    public var isEpisode: Bool { season != nil && episode != nil }

    public init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil, episodeEnd: Int? = nil, quality: [String] = [], folderTitle: String? = nil) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeEnd = episodeEnd
        self.quality = quality
        self.folderTitle = folderTitle
    }
}

/// Deterministic filename and path parser. Pure function of the input, fully unit tested.
///
/// It runs on the full relative path so `Show Name/Season 2/05 - Title.mkv` is understood
/// even though the filename alone has no show name.
public enum FilenameParser {

    // Order matters: the first episode pattern that matches wins.
    private static let episodePatterns: [NSRegularExpression] = [
        // S02E05, s2e5, S02E05E06, S02E05-E06, S02E05-06
        try! NSRegularExpression(pattern: #"(?i)\bS(\d{1,2})\s?E(\d{1,3})(?:\s?-?\s?E?(\d{1,3}))?\b"#),
        // 2x05, 2x05-06
        try! NSRegularExpression(pattern: #"(?i)\b(\d{1,2})x(\d{1,3})(?:-(\d{1,3}))?\b"#),
        // Season 2 Episode 5, Season 2 - Episode 5
        try! NSRegularExpression(pattern: #"(?i)Season\s?(\d{1,2})\D{1,5}Episode\s?(\d{1,3})"#),
        // "Series 2 Episode 5" (UK)
        try! NSRegularExpression(pattern: #"(?i)Series\s?(\d{1,2})\D{1,5}Episode\s?(\d{1,3})"#),
    ]

    private static let seasonFolderPattern = try! NSRegularExpression(pattern: #"(?i)^(?:Season|Series|S)\s?(\d{1,2})$"#)
    // E05 or 05 - Title or 05. Title, only trusted when the parent folder is a season folder.
    private static let bareEpisodePattern = try! NSRegularExpression(pattern: #"(?i)^(?:E|Ep|Episode\s?)?(\d{1,3})(?:\s*[-._]\s*|\s+)"#)
    private static let yearPattern = try! NSRegularExpression(pattern: #"(?<![\dA-Za-z])((?:19|20)\d{2})(?![\dA-Za-z])"#)

    /// Tags that end the title and are kept as quality hints.
    private static let qualityTokens: [String] = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "8k",
        "bluray", "blu-ray", "bdrip", "brrip", "remux", "web-dl", "webdl", "webrip", "web", "hdtv", "dvdrip", "dvd", "hdrip", "cam", "ts", "telesync",
        "x264", "x265", "h264", "h265", "h.264", "h.265", "hevc", "avc", "av1", "xvid", "divx", "vc-1", "vc1",
        "hdr", "hdr10", "hdr10+", "dv", "dovi", "dolby", "vision", "sdr", "10bit", "10-bit", "8bit",
        "atmos", "truehd", "dts", "dts-hd", "dtshd", "dts-x", "ac3", "eac3", "e-ac3", "ddp", "dd5.1", "dd", "aac", "flac", "opus", "mp3", "5.1", "7.1", "2.0",
        "proper", "repack", "internal", "limited", "extended", "unrated", "directors", "theatrical", "imax", "remastered", "multi", "dual", "subbed", "dubbed",
        "amzn", "nf", "dsnp", "hmax", "atvp", "itunes", "hulu",
    ]

    public static func parse(relativePath: String) -> ParsedName {
        let components = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let fileName = components.last else { return ParsedName(title: "") }
        let stem = stripExtension(fileName)
        let parents = Array(components.dropLast())

        var result = ParsedName(title: "")

        // 1. Episode pattern on the filename.
        if let ep = matchEpisode(in: stem) {
            result.season = ep.season
            result.episode = ep.episode
            result.episodeEnd = ep.end
            result.title = clean(String(stem[..<ep.range.lowerBound]))
        }

        // 2. Season folder + bare episode number ("Season 2/05 - Title.mkv").
        if result.episode == nil, let parent = parents.last,
           let seasonMatch = seasonFolderPattern.firstMatch(in: parent, range: fullRange(parent)),
           let season = Int(substring(parent, seasonMatch.range(at: 1))),
           let epMatch = bareEpisodePattern.firstMatch(in: stem, range: fullRange(stem)),
           let episode = Int(substring(stem, epMatch.range(at: 1))) {
            result.season = season
            result.episode = episode
            result.title = ""  // show title comes from the grandparent folder
        }

        // 3. Show title from folders when the filename gave none.
        if result.isEpisode {
            var showFolder: String? = parents.last
            if let p = parents.last, seasonFolderPattern.firstMatch(in: p, range: fullRange(p)) != nil {
                showFolder = parents.dropLast().last
            }
            if let showFolder, !isGenericFolder(showFolder) {
                result.folderTitle = clean(stripYear(showFolder).text)
                if result.title.isEmpty { result.title = result.folderTitle ?? "" }
            }
        }

        // 4. Year and quality.
        if !result.isEpisode {
            let stripped = stripYear(stem)
            result.title = stripped.text
            result.year = stripped.year ?? yearFromFolder(parents.last)
        }
        let (cleanTitle, quality) = splitQuality(result.title)
        result.title = clean(cleanTitle)
        result.quality = quality + qualityTags(in: stem).filter { !quality.contains($0) }

        // 5. Films in their own folder: "Null Island (2024)/null.island.2024.2160p.mkv".
        //    The folder name is human-written and the file is scene noise, so prefer the folder
        //    when it carries the same year, or when the filename gave nothing usable.
        if !result.isEpisode, let parent = parents.last, !isGenericFolder(parent) {
            let folder = stripYear(parent)
            let folderTitle = clean(splitQuality(folder.text).0)
            if !folderTitle.isEmpty, result.title.isEmpty || (folder.year != nil && folder.year == result.year) {
                result.title = folderTitle
                result.year = result.year ?? folder.year
            }
        }

        return result
    }

    // MARK: - Pieces

    private struct EpisodeMatch { var season: Int; var episode: Int; var end: Int?; var range: Range<String.Index> }

    private static func matchEpisode(in text: String) -> EpisodeMatch? {
        for re in episodePatterns {
            guard let m = re.firstMatch(in: text, range: fullRange(text)) else { continue }
            guard let s = Int(substring(text, m.range(at: 1))), let e = Int(substring(text, m.range(at: 2))) else { continue }
            var end: Int?
            if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound { end = Int(substring(text, m.range(at: 3))) }
            // "1x05" could be resolution-like; reject implausible seasons.
            guard s <= 60, e <= 999 else { continue }
            guard let r = Range(m.range, in: text) else { continue }
            return EpisodeMatch(season: s, episode: e, end: end, range: r)
        }
        return nil
    }

    private static func stripYear(_ text: String) -> (text: String, year: Int?) {
        let matches = yearPattern.matches(in: text, range: fullRange(text))
        // Prefer the last plausible year so "2001 A Space Odyssey 1968" keeps the title.
        for m in matches.reversed() {
            let yearString = substring(text, m.range(at: 1))
            guard let y = Int(yearString), y >= 1900, y <= Calendar.current.component(.year, from: Date()) + 1 else { continue }
            let before = (text as NSString).substring(to: m.range.location)
            let after = (text as NSString).substring(from: m.range.location + m.range.length)
            if clean(before).isEmpty {
                // "2012.mkv": the year is the whole title.
                if clean(after).isEmpty && matches.count == 1 { return (text, nil) }
                // "2023-08 Cornwall.mov": a date prefix. Keep the full text as the title.
                return (clean(text), y)
            }
            return (clean(before), y)
        }
        return (text, nil)
    }

    private static func yearFromFolder(_ folder: String?) -> Int? {
        guard let folder else { return nil }
        return stripYear(folder).year
    }

    private static func splitQuality(_ text: String) -> (String, [String]) {
        let tokens = tokenize(text)
        var title: [String] = []
        var quality: [String] = []
        var hitQuality = false
        for tok in tokens {
            let lower = tok.lowercased()
            if qualityTokens.contains(lower) || isReleaseGroup(tok) {
                hitQuality = true
                if qualityTokens.contains(lower) { quality.append(lower) }
                continue
            }
            if hitQuality { continue } // everything after the first tag is noise
            title.append(tok)
        }
        return (title.joined(separator: " "), quality)
    }

    private static func qualityTags(in text: String) -> [String] {
        tokenize(text).map { $0.lowercased() }.filter { qualityTokens.contains($0) }
    }

    private static func isReleaseGroup(_ token: String) -> Bool {
        // "-GROUP" suffix style, or bracketed tags like [YTS] / [rarbg]
        token.hasPrefix("-") || (token.hasPrefix("[") && token.hasSuffix("]"))
    }

    private static func tokenize(_ text: String) -> [String] {
        // Keep "-GROUP" together, split on dots/underscores/spaces otherwise.
        var out: [String] = []
        var current = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == " " || c == "_" || (c == "." && !isDecimalContext(text, i)) {
                if !current.isEmpty { out.append(current); current = "" }
            } else if c == "-" && current.isEmpty == false && text.index(after: i) < text.endIndex && text[text.index(after: i)].isLetter && isLastSegment(text, i) {
                // "Title-GROUP" with no spaces: split and keep the dash on the group.
                out.append(current); current = "-"
            } else {
                current.append(c)
            }
            i = text.index(after: i)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// "5.1", "7.1", "DD5.1", "H.264" keep their dot. Only a single digit on each side counts,
    /// so "S02E05.1080p" and "2022.2160p" are still split into separate tokens.
    private static func isDecimalContext(_ text: String, _ i: String.Index) -> Bool {
        guard i > text.startIndex, text.index(after: i) < text.endIndex else { return false }
        let prevIndex = text.index(before: i), nextIndex = text.index(after: i)
        let prev = text[prevIndex], next = text[nextIndex]
        if (prev == "H" || prev == "h") && next.isNumber { return true }
        guard prev.isNumber, next.isNumber else { return false }
        let prevPrevIsDigit = prevIndex > text.startIndex && text[text.index(before: prevIndex)].isNumber
        let nextNextIsDigit = text.index(after: nextIndex) < text.endIndex && text[text.index(after: nextIndex)].isNumber
        return !prevPrevIsDigit && !nextNextIsDigit
    }

    private static func isLastSegment(_ text: String, _ i: String.Index) -> Bool {
        !text[text.index(after: i)...].contains(where: { $0 == " " || $0 == "." || $0 == "_" })
    }

    private static func isGenericFolder(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["tv", "tv shows", "shows", "series", "films", "movies", "video", "videos", "media", "downloads", "complete", "incoming"].contains(n)
    }

    private static func stripExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return VideoFile.videoExtensions.contains(ext) || VideoFile.subtitleExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    /// Normalise separators to spaces, drop brackets and dangling punctuation, collapse whitespace.
    public static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,;"))
        return s
    }

    private static func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
    private static func substring(_ s: String, _ r: NSRange) -> String { r.location == NSNotFound ? "" : (s as NSString).substring(with: r) }
}
