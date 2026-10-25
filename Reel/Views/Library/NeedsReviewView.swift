import SwiftUI
import MediaCore
import Library
import Metadata

struct NeedsReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var fixing: MediaFile?
    @State private var fixingFolder: ReviewFolder?
    @State private var busy: UUID?
    @State private var busyFolder: String?

    /// One folder's review items, so a decision can be applied to all of them at once: a season of
    /// a show the matcher could not name is usually 10–25 files that all want the same answer.
    struct ReviewFolder: Identifiable {
        var path: String
        var files: [MediaFile]
        var id: String { path }
        var name: String { path.isEmpty ? "/" : path }
    }

    private func folders(_ files: [MediaFile]) -> [ReviewFolder] {
        let grouped = Dictionary(grouping: files) { ($0.relativePath as NSString).deletingLastPathComponent }
        return grouped.keys.sorted().map { ReviewFolder(path: $0, files: grouped[$0]!) }
    }

    var body: some View {
        let files = library.filesNeedingReview()
        List {
            if files.isEmpty {
                ContentUnavailableView("All clear", systemImage: "checkmark.seal", description: Text("Files the app can't match confidently will appear here. Nothing is changed on your drive."))
            } else {
                ForEach(folders(files)) { folder in
                Section {
                    ForEach(folder.files, id: \.id) { f in
                        VStack(alignment: .leading, spacing: 8) {
                            Text((f.relativePath as NSString).lastPathComponent).font(.footnote.weight(.semibold))
                            Text("Best guess: \(guess(f))").font(.caption).foregroundStyle(f.guessTitle == nil ? .red : .yellow)
                            // What TMDb has for the file name, so the usual answer is one tap away.
                            CandidateRow(file: f) { id, kind in resolve(f, kind: kind, tmdbID: id) }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Button("Accept") { resolve(f, kind: f.guessSeason != nil ? .episode : .film) }.buttonStyle(.borderedProminent)
                                    Button("Fix match") { fixing = f }.buttonStyle(.bordered)
                                    Button("Treat as TV") { resolve(f, kind: .episode) }.buttonStyle(.bordered)
                                    Button("Treat as Film") { resolve(f, kind: .film) }.buttonStyle(.bordered)
                                    Button("Ignore", role: .destructive) { try? library.ignoreFile(f) }.buttonStyle(.bordered)
                                }.controlSize(.small)
                            }
                        }
                        .opacity(busy == f.id || busyFolder == folder.path ? 0.5 : 1)
                    }
                } header: {
                    HStack {
                        Text(folder.name).lineLimit(1).truncationMode(.head)
                        Spacer()
                        if folder.files.count > 1 {
                            Menu {
                                Button("Accept all \(folder.files.count)") { resolveAll(folder, kind: nil) }
                                Button("Fix match for all…") { fixingFolder = folder }
                                Button("Treat all as TV") { resolveAll(folder, kind: .episode) }
                                Button("Treat all as Film") { resolveAll(folder, kind: .film) }
                                Button("Ignore all", role: .destructive) { try? library.ignoreFiles(folder.files) }
                            } label: { Label("All \(folder.files.count)", systemImage: "checkmark.circle").font(.caption) }
                        }
                    }
                } footer: {
                    if folder.id == folders(files).last?.id {
                        Text("\(files.count) file\(files.count == 1 ? "" : "s"). Choices are saved in the app and synced; files are never renamed.")
                    }
                }
                }
            }
        }
        .navigationTitle("Needs Review")
        .sheet(item: $fixing) { FixMatchView(file: $0) }
        .sheet(item: $fixingFolder) { FixMatchView(files: $0.files) }
    }

    /// `kind` nil accepts each file's own guess (TV when it has a season number, film otherwise).
    private func resolveAll(_ folder: ReviewFolder, kind: MediaKind?) {
        guard let tmdb = settings.tmdb else { library.lastError = "Add a TMDb API key in Settings first."; return }
        busyFolder = folder.path
        Task {
            if let kind {
                try? await library.resolveReview(folder.files, as: kind, tmdbID: nil, tmdb: tmdb)
            } else {
                let tv = folder.files.filter { $0.guessSeason != nil }, film = folder.files.filter { $0.guessSeason == nil }
                if !tv.isEmpty { try? await library.resolveReview(tv, as: .episode, tmdbID: nil, tmdb: tmdb) }
                if !film.isEmpty { try? await library.resolveReview(film, as: .film, tmdbID: nil, tmdb: tmdb) }
            }
            busyFolder = nil
        }
    }

    private func guess(_ f: MediaFile) -> String {
        guard let t = f.guessTitle, !t.isEmpty else { return "No match" }
        if let s = f.guessSeason, let e = f.guessEpisode { return "TV · \(t) \(MediaFormat.episodeCode(season: s, episode: e))" }
        return "Film · \(t)" + (f.guessYear.map { " (\($0))" } ?? "")
    }

    private func resolve(_ f: MediaFile, kind: MediaKind, tmdbID: Int? = nil) {
        guard let tmdb = settings.tmdb else { library.lastError = "Add a TMDb API key in Settings first."; return }
        busy = f.id
        Task { try? await library.resolveReview(f, as: kind, tmdbID: tmdbID, tmdb: tmdb, providers: settings.providers); busy = nil }
    }

    /// TMDb's top results for the file's name (films, or shows when the name carries an episode
    /// number), as tappable posters. Loaded when the row appears; nothing is chosen on its own.
    struct CandidateRow: View {
        @EnvironmentObject private var settings: AppSettings
        let file: MediaFile
        let choose: (Int, MediaKind) -> Void
        struct Candidate: Identifiable { var id: Int; var title: String; var year: Int?; var poster: String? }
        @State private var candidates: [Candidate]?
        @State private var kind: MediaKind = .film

        var body: some View {
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        Text("TMDb has nothing for “\(FixMatchView.seed(for: file).title)”.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(candidates) { c in
                                    Button { choose(c.id, kind) } label: {
                                        VStack(spacing: 4) {
                                            ArtworkImage(url: ArtworkURL.poster(c.poster), title: c.title, cornerRadius: 6).frame(width: 64, height: 96)
                                            Text(c.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(.primary)
                                            if let y = c.year { Text(String(y)).font(.caption2).foregroundStyle(.secondary) }
                                        }.frame(width: 84)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking up TMDb…").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .task(id: file.id) { await load() }
        }

        private func load() async {
            guard let tmdb = settings.tmdb else { candidates = []; return }
            let seed = FixMatchView.seed(for: file)
            kind = seed.season != nil ? .show : .film
            do {
                if kind == .show {
                    var r = try await tmdb.searchShows(query: seed.title, year: seed.year)
                    if r.isEmpty, seed.year != nil { r = try await tmdb.searchShows(query: seed.title, year: nil) }
                    candidates = r.prefix(6).map { Candidate(id: $0.id, title: $0.name, year: $0.year, poster: $0.posterPath) }
                } else {
                    var r = try await tmdb.searchMovies(query: seed.title, year: seed.year)
                    if r.isEmpty, seed.year != nil { r = try await tmdb.searchMovies(query: seed.title, year: nil) }
                    candidates = r.prefix(6).map { Candidate(id: $0.id, title: $0.title, year: $0.year, poster: $0.posterPath) }
                }
            } catch { candidates = [] }
        }
    }
}

/// Search TMDb and pin an item (or an unmatched file) to a chosen result.
struct FixMatchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var item: MediaItem? = nil
    var file: MediaFile? = nil
    /// A whole folder from Needs Review: the chosen result is applied to every file.
    var files: [MediaFile] = []

    @State private var query = ""
    @State private var year = ""
    @State private var kind: MediaKind = .film
    @State private var films: [TMDbMovieSummary] = []
    @State private var shows: [TMDbShowSummary] = []
    /// Anime mode: AniDB entries, each with where Anime-Lists puts it on TMDb (nil when unmapped).
    struct AnimeHit: Identifiable { var id: Int; var title: String; var target: String?; var tmdbShow: Int?; var tmdbMovie: Int? }
    @State private var anime: [AnimeHit] = []
    @State private var animeMode = false
    @State private var searching = false
    @State private var error: String?
    /// For a show or an episode: every file of the series, ticked ones take the new match. From an
    /// episode the whole series is ticked when "Apply to the whole series" is on.
    @State private var seriesFiles: [MediaFile] = []
    @State private var selected: Set<UUID> = []
    @State private var wholeSeries = true
    @State private var showFiles = false
    @State private var applying = false

    private var series: MediaItem? { item?.kind == .show ? item : item?.show }

    var body: some View {
        NavigationStack {
            List {
                if let series {
                    Section {
                        if item?.kind == .episode {
                            Toggle(isOn: $wholeSeries) {
                                VStack(alignment: .leading) { Text("Apply to the whole series"); Text(wholeSeries ? "All \(seriesFiles.count) files of \(series.title) move to the chosen show." : "Only \(item?.episodeCode ?? "this episode")'s file moves.").font(.caption).foregroundStyle(.secondary) }
                            }
                            .onChange(of: wholeSeries) { _, all in selected = all ? Set(seriesFiles.map(\.id)) : Set((item?.files ?? []).map(\.id)) }
                        }
                        DisclosureGroup(isExpanded: $showFiles) {
                            ForEach(seriesFiles, id: \.id) { f in
                                Button {
                                    if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected.contains(f.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(f.id) ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(f.fileName).font(.caption).lineLimit(2).foregroundStyle(.primary)
                                            Text([f.item?.episodeCode, (f.relativePath as NSString).deletingLastPathComponent].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                        }
                                    }
                                }
                            }
                            HStack {
                                Button("Select all") { selected = Set(seriesFiles.map(\.id)) }
                                Spacer()
                                Button("Select none") { selected = [] }
                            }.font(.caption)
                        } label: {
                            Text("\(selected.count) of \(seriesFiles.count) files will be rematched")
                        }
                    } footer: {
                        Text("Pick the right show below; the ticked files are matched to its episodes by their season and episode numbers.")
                    }
                }
                Section {
                    HStack {
                        TextField("Title", text: $query).textInputAutocapitalization(.words).onSubmit(search)
                        TextField("Year", text: $year).keyboardType(.numberPad).frame(width: 64)
                    }
                    Picker("Type", selection: Binding(get: { animeMode ? 2 : (kind == .film ? 0 : 1) }, set: { v in animeMode = v == 2; if v == 0 { kind = .film } else if v == 1 { kind = .show } })) {
                        Text("Film").tag(0); Text("TV Show").tag(1); Text("Anime").tag(2)
                    }.pickerStyle(.segmented)
                    Button(searching ? "Searching…" : (animeMode ? "Search AniDB" : "Search TMDb"), action: search).disabled(searching || query.isEmpty)
                    if animeMode {
                        Text(settings.animeMatching ? "Anime titles are matched by AniDB's own entries, so a season released under its own name (Alicization – War of Underworld) is found; Anime-Lists then places its episodes on the right TMDb season."
                             : "Turn on Anime matching in Settings → Metadata to search AniDB.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    if animeMode {
                        ForEach(anime) { a in
                            Button { chooseAnime(a) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(a.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(a.target ?? "Not mapped to TMDb by Anime-Lists").font(.caption).foregroundStyle(a.target == nil ? .red : .secondary)
                                }
                            }.disabled(a.target == nil)
                        }
                        if !searching, anime.isEmpty, !query.isEmpty, searchedAnime { Text("No AniDB title contains “\(query)”. Try fewer words.").foregroundStyle(.secondary) }
                    } else if kind == .film {
                        ForEach(films) { m in ResultRow(title: m.title, year: m.year, overview: m.overview, poster: m.posterPath) { choose(m.id) } }
                    } else {
                        ForEach(shows) { s in ResultRow(title: s.name, year: s.year, overview: s.overview, poster: s.posterPath) { choose(s.id) } }
                    }
                } footer: { Text(animeMode ? "AniDB titles, placed on TMDb by Anime-Lists. Episode numbers in the file names are mapped through that entry, so “- 03” of a later cour lands on the right TMDb episode." : "Results from TMDb. Your choice is saved in the app and synced to your other devices. The file is not renamed.") }
            }
            .navigationTitle("Fix Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if applying { ZStack { Color.black.opacity(0.2).ignoresSafeArea(); ProgressView("Rematching \(max(1, selected.count)) files…").padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } } }
            .interactiveDismissDisabled(applying)
            .onAppear {
                // The file's own name seeds the search, not the current match: when the match is
                // wrong its title is exactly what not to search for.
                let sample = file ?? files.first ?? item?.files.first ?? item?.episodes.first?.files.first
                let seed = sample.map(Self.seed(for:))
                query = seed?.title ?? (item?.kind == .episode ? item?.show?.title : item?.title) ?? ""
                year = (seed?.year ?? (item?.kind == .episode ? item?.show?.year : item?.year)).map(String.init) ?? ""
                kind = (item?.kind == .show || item?.kind == .episode || seed?.season != nil) ? .show : .film
                if let series {
                    seriesFiles = series.episodes.flatMap(\.files).sorted { ($0.item?.seasonNumber ?? 0, $0.item?.episodeNumber ?? 0, $0.relativePath) < ($1.item?.seasonNumber ?? 0, $1.item?.episodeNumber ?? 0, $1.relativePath) }
                    selected = Set(seriesFiles.map(\.id))
                }
                if !query.isEmpty { search() }
            }
        }
    }

    @State private var searchedAnime = false

    /// Title, year and episode numbers read from a file's name and folders; the bare name without
    /// its extension when the parser finds no title at all.
    static func seed(for file: MediaFile) -> ParsedName {
        var parsed = FilenameParser.parse(relativePath: file.relativePath)
        if parsed.title.isEmpty { parsed.title = (file.fileName as NSString).deletingPathExtension.replacingOccurrences(of: ".", with: " ") }
        return parsed
    }

    private func search() {
        guard let tmdb = settings.tmdb else { error = "Add a TMDb API key in Settings first."; return }
        searching = true; error = nil
        let y = Int(year)
        Task {
            do {
                if animeMode { try await searchAnime(tmdb: tmdb) }
                else if kind == .film { films = try await tmdb.searchMovies(query: query, year: y) }
                else { shows = try await tmdb.searchShows(query: query, year: y) }
            } catch { self.error = error.localizedDescription }
            searching = false
        }
    }

    /// AniDB's title index, then each hit's TMDb home from Anime-Lists, named via TMDb so the row can
    /// say "Sword Art Online · season 4 from episode 13" rather than an id.
    private func searchAnime(tmdb: TMDbClient) async throws {
        let providers = settings.providers
        guard let anidb = providers.anidb, let lists = providers.animeLists else { error = "Turn on Anime matching in Settings → Metadata first."; return }
        let hits = await anidb.search(query, limit: 20)
        searchedAnime = true
        guard await anidb.isAvailable else { error = "The AniDB title index has not downloaded yet (it needs a network connection once). Try again in a minute."; return }
        var out: [AnimeHit] = []
        var names: [Int: String] = [:]
        for h in hits {
            var hit = AnimeHit(id: h.aid, title: h.title, target: nil)
            if let entry = await lists.entry(forAniDB: h.aid) {
                if let tv = entry.tmdbTV {
                    if names[tv] == nil { names[tv] = (try? await tmdb.show(id: tv))?.name ?? "TMDb show \(tv)" }
                    let first = entry.resolve(anidbSeason: 1, episode: 1)
                    hit.tmdbShow = tv
                    hit.target = names[tv]! + (first.map { " · season \($0.season)" + ($0.episode > 1 ? " from episode \($0.episode)" : "") } ?? "")
                } else if let film = entry.tmdbMovie {
                    if names[film] == nil { names[film] = (try? await tmdb.movie(id: film))?.title ?? "TMDb film \(film)" }
                    hit.tmdbMovie = film
                    hit.target = names[film]! + " · film"
                }
            }
            out.append(hit)
        }
        anime = out
    }

    private func chooseAnime(_ a: AnimeHit) {
        guard let tmdb = settings.tmdb, !applying else { return }
        let providers = settings.providers
        let targetKind: MediaKind = a.tmdbMovie != nil && a.tmdbShow == nil ? .film : .show
        guard let tmdbID = targetKind == .film ? a.tmdbMovie : a.tmdbShow else { return }
        applying = true
        Task {
            defer { applying = false }
            do {
                if let item, series != nil {
                    let chosen = seriesFiles.filter { selected.contains($0.id) }
                    guard !chosen.isEmpty else { error = "Tick at least one file."; return }
                    try await library.fixMatch(item, files: chosen, tmdbID: tmdbID, kind: targetKind, anidbID: a.id, tmdb: tmdb, providers: providers)
                } else if let item { try await library.fixMatch(item, tmdbID: tmdbID, kind: targetKind, anidbID: a.id, tmdb: tmdb, providers: providers) }
                else if let file { try await library.resolveReview(file, as: targetKind == .show ? .episode : .film, tmdbID: tmdbID, anidbID: a.id, tmdb: tmdb, providers: providers) }
                else if !files.isEmpty { try await library.resolveReview(files, as: targetKind == .show ? .episode : .film, tmdbID: tmdbID, anidbID: a.id, tmdb: tmdb, providers: providers) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func choose(_ id: Int) {
        guard let tmdb = settings.tmdb, !applying else { return }
        applying = true
        Task {
            defer { applying = false }
            do {
                if let item, series != nil {
                    let chosen = seriesFiles.filter { selected.contains($0.id) }
                    guard !chosen.isEmpty else { error = "Tick at least one file."; return }
                    try await library.fixMatch(item, files: chosen, tmdbID: id, kind: kind, tmdb: tmdb, providers: settings.providers)
                } else if let item { try await library.fixMatch(item, tmdbID: id, kind: kind, tmdb: tmdb, providers: settings.providers) }
                else if let file { try await library.resolveReview(file, as: kind == .show ? .episode : .film, tmdbID: id, tmdb: tmdb) }
                else if !files.isEmpty { try await library.resolveReview(files, as: kind == .show ? .episode : .film, tmdbID: id, tmdb: tmdb) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    struct ResultRow: View {
        let title: String; let year: Int?; let overview: String?; let poster: String?; let action: () -> Void
        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    ArtworkImage(url: ArtworkURL.poster(poster), title: title, cornerRadius: 6).frame(width: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title + (year.map { " (\($0))" } ?? "")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let overview { Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }
        }
    }
}
