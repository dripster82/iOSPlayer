import Foundation
import MediaCore

/// TMDb's search is literal: a typo in the first word, a season name tacked onto a show, or an
/// extra word a release group added all return nothing. These searches try the title as given,
/// then shorter forms, the way Kodi and Plex do: with the year and without, dropping words from
/// the end ("South Park The Movie" → "South Park"), then from the front ("Teeage Mutant Ninja
/// Turtles" → "Mutant Ninja Turtles"). The scorer still has to agree with whatever comes back.
public extension TMDbClient {
    func searchMoviesForgiving(_ parsed: ParsedName) async throws -> [TMDbMovieSummary] {
        try await Self.forgiving(parsed) { query, year in try await self.searchMovies(query: query, year: year) }
    }

    func searchShowsForgiving(_ parsed: ParsedName) async throws -> [TMDbShowSummary] {
        try await Self.forgiving(parsed) { query, year in try await self.searchShows(query: query, year: year) }
    }

    /// The queries tried, in order, for a title: as given, then trailing words dropped down to two,
    /// then leading words dropped down to two.
    static func queries(for title: String) -> [String] {
        let words = title.split(separator: " ").map(String.init)
        var out = [title]
        if words.count > 2 {
            for n in stride(from: words.count - 1, through: 2, by: -1) { out.append(words.prefix(n).joined(separator: " ")) }
            for n in stride(from: words.count - 1, through: 2, by: -1) { out.append(words.suffix(n).joined(separator: " ")) }
        }
        return out
    }

    private static func forgiving<T>(_ parsed: ParsedName, _ search: (String, Int?) async throws -> [T]) async throws -> [T] {
        guard !parsed.title.isEmpty else { return [] }
        for query in queries(for: parsed.title) {
            var results = try await search(query, parsed.year)
            // A year taken from a folder may be a season's or a re-release's: retry unfiltered.
            if results.isEmpty, parsed.year != nil { results = try await search(query, nil) }
            if !results.isEmpty { return results }
        }
        return []
    }
}
