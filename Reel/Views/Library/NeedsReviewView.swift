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

    private func resolve(_ f: MediaFile, kind: MediaKind) {
        guard let tmdb = settings.tmdb else { library.lastError = "Add a TMDb API key in Settings first."; return }
        busy = f.id
        Task { try? await library.resolveReview(f, as: kind, tmdbID: nil, tmdb: tmdb); busy = nil }
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
                    Picker("Type", selection: $kind) { Text("Film").tag(MediaKind.film); Text("TV Show").tag(MediaKind.show) }.pickerStyle(.segmented)
                    Button(searching ? "Searching…" : "Search TMDb", action: search).disabled(searching || query.isEmpty)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    if kind == .film {
                        ForEach(films) { m in ResultRow(title: m.title, year: m.year, overview: m.overview, poster: m.posterPath) { choose(m.id) } }
                    } else {
                        ForEach(shows) { s in ResultRow(title: s.name, year: s.year, overview: s.overview, poster: s.posterPath) { choose(s.id) } }
                    }
                } footer: { Text("Results from TMDb. Your choice is saved in the app and synced to your other devices. The file is not renamed.") }
            }
            .navigationTitle("Fix Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if applying { ZStack { Color.black.opacity(0.2).ignoresSafeArea(); ProgressView("Rematching \(max(1, selected.count)) files…").padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } } }
            .interactiveDismissDisabled(applying)
            .onAppear {
                let sample = file ?? files.first
                query = (item?.kind == .episode ? item?.show?.title : item?.title) ?? sample?.guessTitle ?? ""
                year = ((item?.kind == .episode ? item?.show?.year : item?.year) ?? sample?.guessYear).map(String.init) ?? ""
                kind = (item?.kind == .show || item?.kind == .episode || sample?.guessSeason != nil) ? .show : .film
                if let series {
                    seriesFiles = series.episodes.flatMap(\.files).sorted { ($0.item?.seasonNumber ?? 0, $0.item?.episodeNumber ?? 0, $0.relativePath) < ($1.item?.seasonNumber ?? 0, $1.item?.episodeNumber ?? 0, $1.relativePath) }
                    selected = Set(seriesFiles.map(\.id))
                }
                if !query.isEmpty { search() }
            }
        }
    }

    private func search() {
        guard let tmdb = settings.tmdb else { error = "Add a TMDb API key in Settings first."; return }
        searching = true; error = nil
        let y = Int(year)
        Task {
            do {
                if kind == .film { films = try await tmdb.searchMovies(query: query, year: y) }
                else { shows = try await tmdb.searchShows(query: query, year: y) }
            } catch { self.error = error.localizedDescription }
            searching = false
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
                    try await library.fixMatch(item, files: chosen, tmdbID: id, kind: kind, tmdb: tmdb)
                } else if let item { try await library.fixMatch(item, tmdbID: id, kind: kind, tmdb: tmdb) }
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
