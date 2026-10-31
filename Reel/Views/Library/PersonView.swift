import SwiftUI
import MediaCore
import Library
import Metadata

/// An actor: what of theirs is in the library, then their whole TMDb filmography with the owned
/// titles marked and tappable.
struct PersonView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let person: PersonRef
    @State private var credits: [TMDbPersonCredit] = []
    /// The stored path, or the one TMDb's person record gives when the title was recorded without it.
    @State private var profile = ""
    /// The TMDb id once known (stored, or found by name), for the link to their page.
    @State private var tmdbID = 0
    @State private var owned: [Int: MediaItem] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var fixMatchTarget: MediaItem?
    @State private var filter: Filter = .all
    enum Filter: String, CaseIterable { case all = "All", films = "Films", tv = "TV" }

    var body: some View {
        let inLibrary = library.items(withCastMember: person.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    if !profile.isEmpty {
                        ArtworkImage(url: ArtworkURL.profile(profile), title: person.name, aspect: 1, cornerRadius: 44).frame(width: 88, height: 88).clipShape(Circle())
                    } else {
                        ArtworkImage.Placeholder(title: person.name).frame(width: 88, height: 88).clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).font(.title2.bold())
                        if !credits.isEmpty {
                            Text("\(credits.count) credits · \(inLibrary.count) in your library").font(.footnote).foregroundStyle(.secondary)
                        }
                        if tmdbID != 0, let url = URL(string: "https://www.themoviedb.org/person/\(tmdbID)") {
                            Link(destination: url) { Label("View on TMDb", systemImage: "arrow.up.right.square").font(.footnote) }
                        }
                    }
                }.padding(.horizontal)

                if !inLibrary.isEmpty {
                    ItemRow(title: "In your library", items: inLibrary, fixMatchTarget: $fixMatchTarget)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Filmography").font(.headline)
                        Spacer()
                        Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 180)
                    }
                    if loading { HStack { ProgressView(); Text("Loading from TMDb…").font(.footnote).foregroundStyle(.secondary) } }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
                    ForEach(shown) { c in
                        if let item = owned[c.id] {
                            NavigationLink(value: item.itemKey) { creditRow(c, owned: true) }.buttonStyle(.plain)
                        } else if let url = URL(string: "https://www.themoviedb.org/\(c.isFilm ? "movie" : "tv")/\(c.id)") {
                            // Not in the library: read about it on TMDb.
                            Link(destination: url) { creditRow(c, owned: false) }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal)
            }.padding(.vertical)
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
        .task(id: person) { await load() }
    }

    /// Newest first; credits without a date (unreleased, obscure) go last. Duplicates (the same show
    /// listed per role) are collapsed.
    private var shown: [TMDbPersonCredit] {
        var seen = Set<Int>()
        return credits
            .filter { filter == .all || (filter == .films ? $0.isFilm : !$0.isFilm) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.date ?? "") > ($1.date ?? "") }
    }

    private func creditRow(_ c: TMDbPersonCredit, owned: Bool) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(url: ArtworkURL.poster(c.posterPath), title: c.displayTitle).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                Text([c.year.map(String.init), c.isFilm ? "Film" : "TV", c.character.flatMap { $0.isEmpty ? nil : "as \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if owned { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
        }
        .padding(8)
        .background(owned ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func load() async {
        guard let tmdb = settings.tmdb else { loading = false; error = "Add a TMDb API key in Settings to see a filmography."; return }
        loading = true; error = nil; profile = person.profilePath
        do {
            var id = person.id
            var found: TMDbPersonSummary?
            if id == 0 {
                // Cast recorded before ids were kept: take TMDb's best match for the name.
                found = try await tmdb.searchPeople(query: person.name).first
                id = found?.id ?? 0
            }
            guard id != 0 else { loading = false; error = "TMDb doesn't know this person."; return }
            tmdbID = id
            if profile.isEmpty {
                if found == nil { found = try? await tmdb.person(id: id) }
                profile = found?.profilePath ?? ""
            }
            if profile != person.profilePath || person.id == 0 { library.recordCastProfile(name: person.name, profilePath: profile, id: id) }
            credits = try await tmdb.personCredits(id: id).filter { ($0.voteCount ?? 0) > 0 || $0.posterPath != nil }
            owned = library.items(tmdbIDs: Set(credits.map(\.id)))
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
