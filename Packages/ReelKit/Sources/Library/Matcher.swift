#if canImport(SwiftData)
import Foundation
import SwiftData
import MediaCore
import Metadata

/// Turns a classified `MediaFile` into a `MediaItem` via TMDb, honouring any `ItemOverride`.
/// Runs inside the Scanner's model actor; not thread-safe on its own.
struct Matcher {
    enum Outcome { case matched, review, skipped }

    let context: ModelContext
    let tmdb: TMDbClient

    func match(_ file: MediaFile) async -> Outcome {
        let parsed = ParsedName(title: file.guessTitle ?? "", year: file.guessYear, season: file.guessSeason, episode: file.guessEpisode)
        let fileKey = ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: file.duration)
        let override = try? fetchOverride(fileKey)
        if override?.hidden == true { file.ignored = true; return .skipped }

        let kind: MediaKind = override?.forcedKind ?? (file.classificationRaw == "episode" ? .episode : .film)
        do {
            switch kind {
            case .episode, .show:
                guard let s = parsed.season, let e = parsed.episode else { return markReview(file) }
                let showID: Int
                if let forced = override?.forcedTMDbID { showID = forced }
                else {
                    let results = try await tmdb.searchShows(query: parsed.title, year: parsed.year)
                    let d = MatchScorer.decideShow(results, parsed: parsed)
                    guard let pick = d.pick else { return markReview(file) }
                    showID = pick.id
                    if d.confidence == .autoLow { file.classificationRaw = "episode-low" }
                }
                let show = try await upsertShow(id: showID, confidence: override != nil ? .manual : (file.classificationRaw == "episode-low" ? .autoLow : .autoHigh))
                let episode = try await upsertEpisode(show: show, season: s, episode: e)
                file.item = episode
                return .matched
            case .film:
                let movieID: Int
                var confidence: MatchConfidence = .autoHigh
                if let forced = override?.forcedTMDbID { movieID = forced; confidence = .manual }
                else {
                    let results = try await tmdb.searchMovies(query: parsed.title, year: parsed.year)
                    let d = MatchScorer.decideMovie(results, parsed: parsed)
                    guard let pick = d.pick else { return markReview(file) }
                    movieID = pick.id
                    confidence = d.confidence
                }
                let film = try await upsertFilm(id: movieID, confidence: confidence)
                file.item = film
                return .matched
            }
        } catch {
            // Network or decode failure: leave the file pending so the next scan retries.
            return .skipped
        }
    }

    private func markReview(_ file: MediaFile) -> Outcome {
        file.classificationRaw = "review"
        return .review
    }

    // MARK: - Upserts

    func upsertFilm(id: Int, confidence: MatchConfidence) async throws -> MediaItem {
        let key = ItemKey.film(tmdbID: id)
        if let existing = try fetchItem(key) { return existing }
        let d = try await tmdb.movie(id: id)
        let item = MediaItem(itemKey: key, kind: .film, title: d.title, year: d.year, tmdbID: id, confidence: confidence)
        item.overview = d.overview
        item.posterPath = d.posterPath
        item.backdropPath = d.backdropPath
        item.rating = d.voteAverage
        item.runtimeMinutes = d.runtime
        item.genres = d.genres?.map(\.name) ?? []
        item.cast = d.credits?.cast.prefix(12).map(\.name) ?? []
        context.insert(item)
        return item
    }

    func upsertShow(id: Int, confidence: MatchConfidence) async throws -> MediaItem {
        let key = ItemKey.show(tmdbID: id)
        if let existing = try fetchItem(key) { return existing }
        let d = try await tmdb.show(id: id)
        let item = MediaItem(itemKey: key, kind: .show, title: d.name, year: d.year, tmdbID: id, confidence: confidence)
        item.overview = d.overview
        item.posterPath = d.posterPath
        item.backdropPath = d.backdropPath
        item.rating = d.voteAverage
        item.runtimeMinutes = d.episodeRunTime?.first
        item.genres = d.genres?.map(\.name) ?? []
        item.cast = d.credits?.cast.prefix(12).map(\.name) ?? []
        item.seasonCount = d.numberOfSeasons ?? d.seasons?.filter { $0.seasonNumber > 0 }.count
        context.insert(item)
        return item
    }

    func upsertEpisode(show: MediaItem, season: Int, episode: Int) async throws -> MediaItem {
        guard let showID = show.tmdbID else { throw TMDbError.decoding("show id") }
        let key = ItemKey.episode(showTMDbID: showID, season: season, episode: episode)
        if let existing = try fetchItem(key) { return existing }
        let item = MediaItem(itemKey: key, kind: .episode, title: "Episode \(episode)", year: show.year, tmdbID: nil, confidence: show.confidence)
        item.seasonNumber = season
        item.episodeNumber = episode
        item.show = show
        item.posterPath = show.posterPath
        if let d = try? await tmdb.episode(showID: showID, season: season, episode: episode) {
            item.title = d.name
            item.tmdbID = d.id
            item.overview = d.overview
            item.stillPath = d.stillPath
            item.runtimeMinutes = d.runtime ?? show.runtimeMinutes
            item.rating = d.voteAverage
            item.airDate = d.airDate.flatMap { ISO8601Day.date($0) }
        }
        context.insert(item)
        return item
    }

    func fetchItem(_ key: String) throws -> MediaItem? {
        var d = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func fetchOverride(_ key: String) throws -> ItemOverride? {
        var d = FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }
}

enum ISO8601Day {
    private static let f: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    static func date(_ s: String) -> Date? { f.date(from: s) }
}
#endif
