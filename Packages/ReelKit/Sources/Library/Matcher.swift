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
    var wikidata: WikidataClient? = nil
    var tvmaze: TVmazeClient? = nil
    var kitsu: KitsuClient? = nil

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
        wikidata = providers.wikidata
        tvmaze = providers.tvmaze
        kitsu = providers.kitsu
    }

    /// Review files are tried too, using the classifier's guess, but only an unambiguous (autoHigh)
    /// result is accepted for them; anything weaker stays in Needs Review.
    func match(_ file: MediaFile) async -> Outcome {
        let parsed = ParsedName(title: file.guessTitle ?? "", year: file.guessYear, season: file.guessSeason, episode: file.guessEpisode)
        let fileKey = ItemKey.unmatched(fileName: file.fileName, size: file.size, duration: file.duration)
        let override = try? fetchOverride(fileKey)
        if override?.hidden == true { file.ignored = true; return .skipped(nil) }

        // The viewer said what this is (Accept, Treat as Film/TV): a title TMDb cannot find still
        // becomes a library item, named from the file, rather than falling back into review.
        let decided = override?.forcedKind != nil
        // Strict (a sure hit only) when the classifier was unsure and the viewer has not weighed in.
        // A file the viewer accepted is matched as leniently as one the classifier was sure about.
        let isReview = file.classificationRaw == "review" && !decided
        let guessed: MediaKind? = file.classificationRaw == "review" ? file.guessKindRaw.flatMap(MediaKind.init(rawValue:)) : (file.classificationRaw == "episode" ? .episode : .film)
        guard let kind = override?.forcedKind ?? guessed, !parsed.title.isEmpty || override?.forcedTMDbID != nil else { return markReview(file) }
        let folderTitle = FilenameParser.parse(relativePath: file.relativePath).folderTitle
        file.guessKindRaw = kind.rawValue   // so a later scan retries this file with the same guess
        file.suggestedTMDbID = nil; file.suggestionSource = nil
        do {
            switch kind {
            case .episode, .show:
                guard let s = parsed.season, let e = parsed.episode else { return markReview(file) }
                let showID: Int
                var season = s, episode = e
                var confidence: MatchConfidence = .autoHigh
                if let aid = override?.forcedAniDBID, let animeLists, let entry = await animeLists.entry(forAniDB: aid),
                   let target = entry.resolve(anidbSeason: s == 0 ? 0 : 1, episode: e) {
                    // The viewer named the AniDB entry; Anime-Lists says which TMDb season and episode that is.
                    showID = target.tmdbShow; season = target.season; episode = target.episode; confidence = .manual
                }
                else if let forced = override?.forcedTMDbID { showID = forced; confidence = .manual }
                else if let anime = await resolveAnime(parsed) {
                    // AniDB knows the title exactly and Anime-Lists says where it sits on TMDb.
                    showID = anime.tmdbShow; season = anime.season; episode = anime.episode
                }
                else {
                    if let found = try await findShow(parsed, folderTitle: folderTitle, strict: isReview) { showID = found.0; confidence = found.1 }
                    else if let viaTVDB = try await resolveShowViaTVDB(parsed) { showID = viaTVDB; confidence = .autoLow }
                    else if let alone = await secondOpinionShow(parsed, file: file, picked: nil) { showID = alone; confidence = .autoHigh }
                    else if decided {
                        let show = try upsertLocalShow(parsed, confidence: .manual)
                        file.item = try upsertLocalEpisode(show: show, parsed: parsed, season: s, episode: e)
                        file.classificationRaw = "episode"
                        file.pendingSync = true; file.updatedAt = Date()
                        return .matched
                    }
                    else { return markReview(file) }
                }
                if confidence == .autoLow, await secondOpinionShow(parsed, file: file, picked: showID) == showID { confidence = .autoHigh }
                let show = try await upsertShow(id: showID, confidence: confidence)
                let episodeItem = try await upsertEpisode(show: show, season: season, episode: episode)
                let placeholder = file.item
                file.item = episodeItem
                retirePlaceholder(placeholder, replacedBy: episodeItem)
                file.classificationRaw = confidence == .autoLow ? "episode-low" : "episode"
                file.pendingSync = true; file.updatedAt = Date()
                return .matched
            case .film:
                let movieID: Int
                var confidence: MatchConfidence = .autoHigh
                if let aid = override?.forcedAniDBID, let animeLists, let film = await animeLists.entry(forAniDB: aid)?.tmdbMovie { movieID = film; confidence = .manual }
                else if let forced = override?.forcedTMDbID { movieID = forced; confidence = .manual }
                else if let animeFilm = await resolveAnimeFilm(parsed) { movieID = animeFilm }
                else {
                    if let found = try await findMovie(parsed, folderTitle: folderTitle, strict: isReview) {
                        movieID = found.0
                        confidence = found.1
                        if confidence == .autoLow, await secondOpinionFilm(parsed, file: file, picked: movieID) == movieID { confidence = .autoHigh }
                    } else if let alone = await secondOpinionFilm(parsed, file: file, picked: nil) {
                        movieID = alone; confidence = .autoHigh
                    } else {
                        guard decided else { return markReview(file) }
                        file.item = try upsertLocalFilm(parsed, confidence: .manual)
                        file.classificationRaw = "film"
                        file.pendingSync = true; file.updatedAt = Date()
                        return .matched
                    }
                }
                let film = try await upsertFilm(id: movieID, confidence: confidence)
                let placeholder = file.item
                file.item = film
                retirePlaceholder(placeholder, replacedBy: film)
                file.classificationRaw = "film"
                file.pendingSync = true; file.updatedAt = Date()
                return .matched
            }
        } catch {
            // Network or decode failure: leave the file pending so the next scan retries.
            return .skipped(error.localizedDescription)
        }
    }

    // MARK: - Searching until the scorer agrees

    /// The titles to try: the file's, then the folder's when it says something different (a special
    /// filed under its own name, "Family Guy {400mn}.mkv" in "Something, Something, Something, Dark Side").
    private func titlesToTry(_ parsed: ParsedName, folderTitle: String?) -> [String] {
        var out = [parsed.title]
        if let f = folderTitle, !f.isEmpty, MatchScorer.normalise(f) != MatchScorer.normalise(parsed.title) { out.append(f) }
        return out
    }

    /// Each query form in turn (as given, trailing words dropped, leading words dropped; with the
    /// year, then without) until TMDb returns something the scorer will stand behind. Stopping at the
    /// first non-empty answer was not enough: a shortened query often returns the wrong film first.
    private func findMovie(_ parsed: ParsedName, folderTitle: String?, strict: Bool) async throws -> (Int, MatchConfidence)? {
        for title in titlesToTry(parsed, folderTitle: folderTitle) {
            let wanted = ParsedName(title: title, year: parsed.year)
            for query in TMDbClient.queries(for: title) {
                for year in Set([parsed.year, nil]).sorted(by: { ($0 ?? 0) > ($1 ?? 0) }) {
                    let results = try await tmdb.searchMovies(query: query, year: year)
                    guard !results.isEmpty else { continue }
                    let d = MatchScorer.decideMovie(results, parsed: wanted, yearFiltered: year != nil)
                    if let pick = d.pick, !strict || d.confidence == .autoHigh { return (pick.id, d.confidence) }
                }
            }
        }
        return nil
    }

    private func findShow(_ parsed: ParsedName, folderTitle: String?, strict: Bool) async throws -> (Int, MatchConfidence)? {
        for title in titlesToTry(parsed, folderTitle: folderTitle) {
            let wanted = ParsedName(title: title, year: parsed.year)
            for query in TMDbClient.queries(for: title) {
                for year in Set([parsed.year, nil]).sorted(by: { ($0 ?? 0) > ($1 ?? 0) }) {
                    let results = try await tmdb.searchShows(query: query, year: year)
                    guard !results.isEmpty else { continue }
                    let d = MatchScorer.decideShow(results, parsed: wanted, yearFiltered: year != nil)
                    if let pick = d.pick, !strict || d.confidence == .autoHigh { return (pick.id, d.confidence) }
                }
            }
        }
        return nil
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
            var targets: [AnimeLists.Entry.Target] = [], aids: [Int] = []
            for hit in await anidb.lookup(candidate) {
                if let entry = await animeLists.entry(forAniDB: hit.aid), let target = entry.resolve(anidbSeason: anidbSeason, episode: e) {
                    targets.append(target); aids.append(hit.aid)
                }
            }
            // Two different shows sharing a synonym is ambiguous; one show (even via several entries) is fine.
            // Kitsu breaks a tie: the entries its own search for the title maps to AniDB are the ones kept.
            let shows = Set(targets.map(\.tmdbShow))
            if shows.count == 1 { return targets[0] }
            if shows.count > 1 {
                if let kitsu, let hits = try? await kitsu.searchAnime(title: candidate) {
                    let known = Set(hits.compactMap(\.anidbID))
                    let kept = aids.enumerated().filter { known.contains($0.element) }.map { targets[$0.offset] }
                    if Set(kept.map(\.tmdbShow)).count == 1 {
                        Diagnostics.log("match", "Kitsu settles \(candidate) → tmdb show \(kept[0].tmdbShow) (\(shows.count) AniDB entries shared the name)")
                        return kept[0]
                    }
                }
                return nil
            }
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

    // MARK: - Second opinions (Wikidata, TVmaze)

    /// Whether a hit from another database is talking about the same release as the file name:
    /// same year, give or take one for regional release dates, or no year to compare.
    private func sameYear(_ hit: SecondOpinionHit, _ parsed: ParsedName) -> Bool {
        guard let y = parsed.year, let h = hit.year else { return true }
        return abs(y - h) <= 1
    }
    private func sameTitle(_ hit: SecondOpinionHit, _ parsed: ParsedName) -> Bool {
        opinionNormalise(hit.title) == opinionNormalise(parsed.title)
    }

    /// Wikidata's view of a film. With `picked` (TMDb's weak answer): returns it when Wikidata has an
    /// entity of that year with the same TMDb id, so the match can be promoted; otherwise an exact-title
    /// entity becomes the file's suggestion. Without `picked` (TMDb drew a blank): returns the TMDb id
    /// of the one entity with exactly this title and year, enough to match on; a title without a year
    /// is only ever a suggestion.
    private func secondOpinionFilm(_ parsed: ParsedName, file: MediaFile, picked: Int?) async -> Int? {
        guard let wikidata, !parsed.title.isEmpty, let hits = try? await wikidata.searchFilms(title: parsed.title) else { return nil }
        let consistent = hits.filter { $0.tmdbID != nil && sameYear($0, parsed) }
        if let picked {
            if consistent.contains(where: { $0.tmdbID == picked }) {
                Diagnostics.log("match", "Wikidata agrees: \(parsed.title) → tmdb \(picked)")
                return picked
            }
            if let other = consistent.first(where: { sameTitle($0, parsed) }), let id = other.tmdbID, id != picked {
                file.suggestedTMDbID = id; file.suggestionSource = "Wikidata"
                Diagnostics.log("match", "Wikidata differs: \(parsed.title) → tmdb \(id), TMDb picked \(picked)")
            }
            return nil
        }
        let exact = consistent.filter { sameTitle($0, parsed) }
        let ids = Set(exact.compactMap(\.tmdbID))
        guard ids.count == 1, let id = ids.first else { return nil }
        if parsed.year != nil, exact.contains(where: { $0.year != nil }) {
            Diagnostics.log("match", "Wikidata matches \(parsed.title) (\(parsed.year!)) → tmdb \(id)")
            return id
        }
        file.suggestedTMDbID = id; file.suggestionSource = "Wikidata"
        return nil
    }

    /// TVmaze's view of a show, with the same contract as `secondOpinionFilm`. TVmaze gives IMDb and
    /// TheTVDB ids, which TMDb's find endpoint maps to a TMDb show; at most three hits are mapped.
    private func secondOpinionShow(_ parsed: ParsedName, file: MediaFile, picked: Int?) async -> Int? {
        guard let tvmaze, !parsed.title.isEmpty, let hits = try? await tvmaze.searchShows(title: parsed.title) else { return nil }
        let consistent = hits.filter { sameYear($0, parsed) && ($0.imdbID != nil || $0.tvdbID != nil) }
        func tmdbID(_ hit: SecondOpinionHit) async -> Int? {
            if let imdb = hit.imdbID, let found = try? await tmdb.findShow(imdbID: imdb) { return found.id }
            if let tvdb = hit.tvdbID, let found = try? await tmdb.findShow(tvdbID: tvdb) { return found.id }
            return nil
        }
        if let picked {
            for hit in consistent.prefix(3) where await tmdbID(hit) == picked {
                Diagnostics.log("match", "TVmaze agrees: \(parsed.title) → tmdb show \(picked)")
                return picked
            }
            if let other = consistent.first(where: { sameTitle($0, parsed) }), let id = await tmdbID(other), id != picked {
                file.suggestedTMDbID = id; file.suggestionSource = "TVmaze"
                Diagnostics.log("match", "TVmaze differs: \(parsed.title) → tmdb show \(id), TMDb picked \(picked)")
            }
            return nil
        }
        let exact = consistent.filter { sameTitle($0, parsed) }
        guard !exact.isEmpty, exact.count <= 3 else { return nil }
        var ids = Set<Int>()
        for hit in exact { if let id = await tmdbID(hit) { ids.insert(id) } }
        guard ids.count == 1, let id = ids.first else { return nil }
        if parsed.year != nil, exact.contains(where: { $0.year != nil }) {
            Diagnostics.log("match", "TVmaze matches \(parsed.title) (\(parsed.year!)) → tmdb show \(id)")
            return id
        }
        file.suggestedTMDbID = id; file.suggestionSource = "TVmaze"
        return nil
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

    /// Needs Review, and meanwhile a placeholder in Films or TV Shows named from the file, so the
    /// library shows everything it has even before the viewer has settled what it is.
    private func markReview(_ file: MediaFile) -> Outcome {
        file.classificationRaw = "review"
        file.pendingSync = true; file.updatedAt = Date()
        if file.item == nil || file.item?.itemKey.hasPrefix("local-") == true {
            let parsed = ParsedName(title: file.guessTitle ?? "", year: file.guessYear, season: file.guessSeason, episode: file.guessEpisode)
            if !parsed.title.isEmpty {
                let previous = file.item
                if let s = parsed.season, let e = parsed.episode, file.guessKindRaw != MediaKind.film.rawValue {
                    if let show = try? upsertLocalShow(parsed, confidence: .unmatched), let ep = try? upsertLocalEpisode(show: show, parsed: parsed, season: s, episode: e) { file.item = ep }
                } else if let film = try? upsertLocalFilm(parsed, confidence: .unmatched) {
                    file.item = film
                }
                if let previous, previous !== file.item { retirePlaceholder(previous, replacedBy: file.item) }
            }
        }
        return .review
    }

    /// A placeholder the file has moved on from is hidden and marked for the launch-time purge
    /// (a page may still hold it); its show goes too when no episode has a file left.
    private func retirePlaceholder(_ previous: MediaItem?, replacedBy item: MediaItem?) {
        guard let previous, previous !== item, previous.itemKey.hasPrefix("local-") else { return }
        if previous.files.isEmpty || previous.files.allSatisfy({ $0.item !== previous }) {
            previous.pendingDeletion = true; previous.hidden = true; previous.pendingSync = true; previous.updatedAt = Date()
            if let show = previous.show, show !== item?.show, show.itemKey.hasPrefix("local-"),
               show.episodes.allSatisfy({ $0.pendingDeletion || $0.files.isEmpty }) {
                show.pendingDeletion = true; show.hidden = true; show.pendingSync = true; show.updatedAt = Date()
            }
        }
    }

    // MARK: - Upserts

    func upsertFilm(id: Int, confidence: MatchConfidence) async throws -> MediaItem {
        let key = ItemKey.film(tmdbID: id)
        if let existing = try fetchItem(key) {
            if existing.confidence == .autoLow, confidence == .autoHigh { existing.confidence = .autoHigh; existing.pendingSync = true; existing.updatedAt = Date() }
            return existing
        }
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
        if let existing = try fetchItem(key) {
            if existing.confidence == .autoLow, confidence == .autoHigh { existing.confidence = .autoHigh; existing.pendingSync = true; existing.updatedAt = Date() }
            return existing
        }
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

    // MARK: Items TMDb does not know

    func upsertLocalFilm(_ parsed: ParsedName, confidence: MatchConfidence) throws -> MediaItem {
        let key = ItemKey.localFilm(title: parsed.title, year: parsed.year)
        if let existing = try fetchItem(key) {
            if confidence == .manual, existing.confidence != .manual { existing.confidenceRaw = confidence.rawValue; existing.pendingSync = true; existing.updatedAt = Date() }
            if existing.pendingDeletion { existing.pendingDeletion = false; existing.hidden = false }
            return existing
        }
        let item = MediaItem(itemKey: key, kind: .film, title: parsed.title, year: parsed.year, tmdbID: nil, confidence: confidence)
        item.pendingSync = true; item.updatedAt = Date()
        context.insert(item)
        return item
    }

    func upsertLocalShow(_ parsed: ParsedName, confidence: MatchConfidence) throws -> MediaItem {
        let key = ItemKey.localShow(title: parsed.title)
        if let existing = try fetchItem(key) {
            if confidence == .manual, existing.confidence != .manual { existing.confidenceRaw = confidence.rawValue; existing.pendingSync = true; existing.updatedAt = Date() }
            if existing.pendingDeletion { existing.pendingDeletion = false; existing.hidden = false }
            return existing
        }
        let item = MediaItem(itemKey: key, kind: .show, title: parsed.title, year: parsed.year, tmdbID: nil, confidence: confidence)
        item.pendingSync = true; item.updatedAt = Date()
        context.insert(item)
        return item
    }

    func upsertLocalEpisode(show: MediaItem, parsed: ParsedName, season: Int, episode: Int) throws -> MediaItem {
        let key = ItemKey.localEpisode(showTitle: parsed.title, season: season, episode: episode)
        if let existing = try fetchItem(key) {
            if existing.pendingDeletion { existing.pendingDeletion = false; existing.hidden = false }
            return existing
        }
        let item = MediaItem(itemKey: key, kind: .episode, title: "Episode \(episode)", year: show.year, tmdbID: nil, confidence: show.confidence)
        item.seasonNumber = season
        item.episodeNumber = episode
        item.show = show
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
