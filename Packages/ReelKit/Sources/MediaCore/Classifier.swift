import Foundation

/// Decision for a scanned file before online matching.
public enum Classification: Equatable, Sendable {
    case episode(ParsedName)
    case film(ParsedName)
    /// Can't decide with confidence; shown in Needs Review with the best guess.
    case needsReview(ParsedName, guess: MediaKind?)
    /// Not media we want in the library (excluded folder, sample file, trailer).
    case ignore
}

/// Combines the filename parse with folder hints and user tags. Pure function, unit tested.
public enum Classifier {

    public static func classify(relativePath: String, folderTag: FolderTag?) -> Classification {
        let parsed = FilenameParser.parse(relativePath: relativePath)
        let lower = relativePath.lowercased()

        if folderTag == .excluded { return .ignore }
        if isSampleOrExtra(lower) { return .ignore }

        // User tags override everything except an obvious episode pattern inside a Films folder,
        // which still goes to review so we never silently misfile.
        switch folderTag {
        case .tv?:
            if parsed.isEpisode { return .episode(parsed) }
            return .needsReview(parsed, guess: .episode)
        case .films?:
            if parsed.isEpisode { return .needsReview(parsed, guess: .episode) }
            if !parsed.title.isEmpty { return .film(parsed) }
            return .needsReview(parsed, guess: .film)
        default:
            break
        }

        var tvScore = 0, filmScore = 0
        if parsed.isEpisode { tvScore += 5 }
        if parsed.year != nil && !parsed.isEpisode { filmScore += 3 }
        for hint in ["/tv/", "/tv shows/", "/shows/", "/series/"] where lower.contains(hint) || lower.hasPrefix(hint.dropFirst()) { tvScore += 2 }
        for hint in ["/films/", "/movies/", "/cinema/", "/film/", "/movie/"] where lower.contains(hint) || lower.hasPrefix(hint.dropFirst()) { filmScore += 2 }
        if lower.range(of: #"/(season|series) ?\d+/"#, options: .regularExpression) != nil { tvScore += 3 }

        if parsed.isEpisode, tvScore >= filmScore { return .episode(parsed) }
        if parsed.isEpisode { return .needsReview(parsed, guess: .episode) }
        if parsed.title.isEmpty { return .needsReview(parsed, guess: nil) }
        if filmScore > tvScore { return .film(parsed) }
        if parsed.year != nil { return .film(parsed) }
        // A bare title with no year and no folder hint is a guess, not a decision.
        return .needsReview(parsed, guess: filmScore >= tvScore ? .film : .episode)
    }

    private static func isSampleOrExtra(_ lower: String) -> Bool {
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        if name.hasPrefix("sample") || name.contains("-sample.") || name.contains(".sample.") { return true }
        if lower.contains("/extras/") || lower.contains("/featurettes/") || lower.contains("/trailers/") { return true }
        if name.hasSuffix("-trailer.mp4") || name.hasSuffix("-trailer.mkv") { return true }
        return false
    }
}
