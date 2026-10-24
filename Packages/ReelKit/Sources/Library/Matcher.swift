#if canImport(SwiftData)
import Foundation
import SwiftData
import MediaCore
import Metadata

/// Turns a classified `MediaFile` into a `MediaItem` via TMDb, honouring any `ItemOverride`.
/// Runs inside the Scanner's model actor; not thread-safe on its own.
struct Matcher {
    enum Outcome: Equatable {
        case matched, review
        /// Left for the next scan. Carries the reason so the UI can show why nothing matched.
        case skipped(String?)
    }

    let context: ModelContext
    let tmdb: TMDbClient
    var tvdb: TVDBClient? = nil
    var anidb: AniDBTitles? = nil
    var animeLists: AnimeLists? = nil

    init(context: ModelContext, tmdb: TMDbClient) {
        self.context = context
        self.tmdb = tmdb
    }

    init(context: ModelContext, tmdb: TMDbClient, providers: MetadataProviders) {
        self.context = context
        self.tmdb = tmdb
        tvdb = providers.tvdb
        anidb = providers.anidb
        animeLists = providers.animeLists
    }

    /// Review files are tried too, using the classifier's guess, but only an unambiguous (autoHigh)
    /// result is accepted for them; anything weaker stays in Needs Review.
    func match(_ file: MediaFile) async -> Outcome {
        let parsed = ParsedName(title: file.guessTitle ?? "", year: file.guessYear, season: file.guessSeason, episode: file.guessEpisode)
        let fileKey = ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: file.duration)
        let override = try? fetchOverride(fileKey)
        if override?.hidden == true { file.ignored = true; return .skipped(nil) }

        let isReview = file.classificationRaw == "review"
        let guessed: MediaKind? = isReview ? file.guessKindRaw.flatMap(MediaKind.init(rawValue:)) : (file.classificationRaw == "episode" ? .episode : .film)
        guard let kind = override?.forcedKind ?? guessed, !parsed.title.isEmpty || override?.forcedTMDbID != nil else { return markReview(file) }
        file.guessKindRaw = kind.rawValue   // so a later scan retries this file with the same guess
        do {
            switch kind {
            case .episode, .show:
                guard let s = parsed.season, let e = parsed.episode else { return markReview(file) }
                let showID: Int
                var season = s, episode = e
                var confidence: MatchConfidence = .autoHigh
                if let forced = override?.forcedTMDbID { showID = forced; confidence = .manual }
                else if let anime = await resolveAnime(parsed) {
                    // AniDB knows the title exactly and Anime-Lists says where it sits on TMDb.
                    showID = anime.tmdbShow; season = anime.season; episode = anime.episode
                }
                else {
                    let results = try await searchShowsShortening(parsed)
                    let d = MatchScorer.decideShow(results, parsed: parsed)
                    if let pick = d.pick, !isReview || d.confidence == .autoHigh { showID = pick.id; confidence = d.confidence }
                    else if let viaTVDB = try await resolveShowViaTVDB(parsed) { showID = viaTVDB; confidence = .autoLow }
                    else { return markReview(file) }
                }
                let show = try await upsertShow(id: showID, confidence: confidence)
                let episodeItem = try await upsertEpisode(show: show, season: season, episode: episode)
                file.item = episodeItem
                file.classificationRaw = confidence == .autoLow ? "episode-low" : "episode"
                file.pendingSync = true; file.updatedAt = Date()
                return .matched
            case .film:
                let movieID: Int
                var confidence: MatchConfidence = .autoHigh
                if let forced = override?.forcedTMDbID { movieID = forced; confidence = .manual }
                else if let animeFilm = await resolveAnimeFilm(parsed) { movieID = animeFilm }
                else {
                    let results = try await searchMoviesShortening(parsed)
                    let d = MatchScorer.decideMovie(results, parsed: parsed)
                    guard let pick = d.pick, !isReview || d.confidence == .autoHigh else { return markReview(file) }
                    movieID = pick.id
                    confidence = d.confidence
                }
                let film = try await upsertFilm(id: movieID, confidence: confidence)
                file.item = film
                file.classificationRaw = "film"
                file.pendingSync = true; file.updatedAt = Date()
                return .matched
            }
        } catch {
            // Network or decode failure: leave the file pending so the next scan retries.
            return .skipped(error.localizedDescription)
        }
    }

    /// "Sword Art Online Alicization War of Underworld" is a season, not a show, so TMDb returns nothing.
    /// Drop trailing words until something comes back, as Kodi and Plex do; the scorer still has to agree.
    private func searchShowsShortening(_ parsed: ParsedName) async throws -> [TMDbShowSummary] {
        var words = parsed.title.split(separator: " ").map(String.init)
        var query = parsed.title
        while true {
            var results = try await tmdb.searchShows(query: query, year: parsed.year)
            // A year taken from a folder may be a season's year, not the show's: retry unfiltered.
            if results.isEmpty, parsed.year != nil { results = try await tmdb.searchShows(query: query, year: nil) }
            if !results.isEmpty || words.count <= 2 { return results }
            words.removeLast()
            query = words.joined(separator: " ")
        }
    }

    // MARK: - Anime (AniDB titles + Anime-Lists → TMDb)

    /// Titles to try against AniDB. "Title" with season 2 is usually a separate AniDB entry called
    /// "Title 2nd Season" / "Title II" / "Title Season 2"; the plain title would map to season 1.
    private func animeCandidates(_ parsed: ParsedName) -> [String] {
        let t = parsed.title
        guard let s = parsed.season, s >= 2 else { return [t] }
        let ordinal = ["", "", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th"][min(s, 9)]
        let roman = ["", "", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"][min(s, 9)]
        return ["\(t) \(ordinal) Season", "\(t) Season \(s)", "\(t) \(roman)", "\(t) \(s)", "\(t) Part \(s)"]
    }

    private func resolveAnime(_ parsed: ParsedName) async -> AnimeLists.Entry.Target? {
        guard let anidb, let animeLists, !parsed.title.isEmpty, let e = parsed.episode else { return nil }
        let anidbSeason = parsed.season == 0 ? 0 : 1
        for candidate in animeCandidates(parsed) {
            var targets: [AnimeLists.Entry.Target] = []
            for hit in await anidb.lookup(candidate) {
                if let entry = await animeLists.entry(forAniDB: hit.aid), let target = entry.resolve(anidbSeason: anidbSeason, episode: e) {
                    targets.append(target)
                }
            }
            // Two different shows sharing a synonym is ambiguous; one show (even via several entries) is fine.
            let shows = Set(targets.map(\.tmdbShow))
            if shows.count == 1 { return targets[0] }
            if shows.count > 1 { return nil }
        }
        return nil
    }

    private func resolveAnimeFilm(_ parsed: ParsedName) async -> Int? {
        guard let anidb, let animeLists, !parsed.title.isEmpty else { return nil }
        let ids = await withTaskGroup(of: Int?.self) { group -> Set<Int> in
            for hit in await anidb.lookup(parsed.title) {
                group.addTask { await animeLists.entry(forAniDB: hit.aid)?.tmdbMovie }
            }
            var out = Set<Int>()
            for await id in group { if let id { out.insert(id) } }
            return out
        }
        return ids.count == 1 ? ids.first : nil
    }

    // MARK: - TheTVDB fallback

    /// When TMDb's search draws a blank, ask TheTVDB and bridge back to TMDb through the remote id
    /// TheTVDB stores, or TMDb's own /find by TheTVDB id. Items stay TMDb-backed either way.
    private func resolveShowViaTVDB(_ parsed: ParsedName) async throws -> Int? {
        guard let tvdb, !parsed.title.isEmpty else { return nil }
        let results = try await tvdb.searchSeries(query: parsed.title, year: parsed.year)
        let wanted = MatchScorer.normalise(parsed.title)
        let ordered = results.sorted { (MatchScorer.normalise($0.name) == wanted ? 0 : 1) < (MatchScorer.normalise($1.name) == wanted ? 0 : 1) }
        for series in ordered.prefix(3) {
            if let id = series.tmdbID { return id }
            if let found = try? await tmdb.findShow(tvdbID: series.id) { return found.id }
        }
        return nil
    }

    /// "South Park The Movie (1999)" finds nothing; "South Park" with the year finds Bigger, Longer & Uncut.
    private func searchMoviesShortening(_ parsed: ParsedName) async throws -> [TMDbMovieSummary] {
        var words = parsed.title.split(separator: " ").map(String.init)
        var query = parsed.title
        while true {
            var results = try await tmdb.searchMovies(query: query, year: parsed.year)
            if results.isEmpty, parsed.year != nil { results = try await tmdb.searchMovies(query: query, year: nil) }
            if !results.isEmpty || words.count <= 2 { return results }
            words.removeLast()
            query = words.joined(separator: " ")
        }
    }

    private func markReview(_ file: MediaFile) -> Outcome {
        file.classificationRaw = "review"
        file.pendingSync = true; file.updatedAt = Date()
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
        item.castProfiles = d.credits?.cast.prefix(12).map { $0.profilePath ?? "" } ?? []
        item.castIDs = d.credits?.cast.prefix(12).map(\.id) ?? []
        item.castPhotosCheckedAt = Date()
        item.collectionID = d.belongsToCollection?.id
        item.collectionName = d.belongsToCollection?.name
        item.collectionCheckedAt = Date()
        item.studios = d.productionCompanies?.map(\.name) ?? []
        item.studioLogos = d.productionCompanies?.map { $0.logoPath ?? "" } ?? []
        item.keywords = d.keywords?.names ?? []
        item.collectionPosterPath = d.belongsToCollection?.posterPath
        item.universeCheckedAt = Date()
        item.pendingSync = true; item.updatedAt = Date()
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
        if let tvdb = d.externalIDs?.tvdbID { item.tvdbID = tvdb }
        item.rating = d.voteAverage
        item.runtimeMinutes = d.episodeRunTime?.first
        item.genres = d.genres?.map(\.name) ?? []
        item.cast = d.credits?.cast.prefix(12).map(\.name) ?? []
        item.castProfiles = d.credits?.cast.prefix(12).map { $0.profilePath ?? "" } ?? []
        item.castIDs = d.credits?.cast.prefix(12).map(\.id) ?? []
        item.castPhotosCheckedAt = Date()
        item.seasonCount = d.numberOfSeasons ?? d.seasons?.filter { $0.seasonNumber > 0 }.count
        item.pendingSync = true; item.updatedAt = Date()
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
        item.pendingSync = true; item.updatedAt = Date()
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
