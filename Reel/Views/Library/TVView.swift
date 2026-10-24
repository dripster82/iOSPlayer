import SwiftUI
import MediaCore
import Library
import Metadata

struct TVView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var quick: FilterBar.Quick = .all
    @State private var genre: String?
    @State private var decade: String?
    @State private var fixMatchTarget: MediaItem?
    @State private var all: [MediaItem] = []
    @State private var genres: [String] = []

    var body: some View {
        let shown = filtered(all)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FilterBar(quick: $quick, genre: $genre, decade: $decade, genres: genres, decades: decades(all))
                if shown.isEmpty {
                    ContentUnavailableView("No shows match", systemImage: "tv", description: Text("Try clearing a filter.")).padding(.top, 60)
                } else {
                    ItemGrid(items: shown, fixMatchTarget: $fixMatchTarget)
                }
            }.padding(.vertical, 8)
        }
        .navigationTitle("TV Shows")
        .refreshFromLibrary { all = library.items(kind: .show); genres = library.allGenres(kind: .show) }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }

    private func filtered(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { s in
            switch quick {
            case .unwatched: if library.unwatchedCount(s) == 0 { return false }
            case .favourites: if !library.isFavourite(s.itemKey) { return false }
            default: break
            }
            if let genre, !s.genres.contains(genre) { return false }
            if let decade, FilterBar.decade(s.year) != decade { return false }
            return true
        }
    }
    private func decades(_ items: [MediaItem]) -> [String] { Array(Set(items.compactMap { FilterBar.decade($0.year) })).sorted(by: >) }
}

private func row(_ title: String, _ subtitle: String, poster: String?) -> some View {
    HStack(spacing: 12) {
        if let poster, let url = ArtworkURL.poster(poster) {
            ArtworkImage(url: url, title: title, aspect: 1, cornerRadius: 8).frame(width: 44, height: 44)
        } else {
            ArtworkImage.Placeholder(title: title).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
    }
}

struct FilmsView: View {
    @EnvironmentObject private var library: LibraryStore
    enum Sort: String, CaseIterable { case title = "Title", year = "Year, newest first", rating = "Rating", runtime = "Runtime", added = "Date added" }
    @State private var quick: FilterBar.Quick = .all
    @State private var genre: String?
    @State private var decade: String?
    @State private var sort: Sort = .title
    @State private var fixMatchTarget: MediaItem?
    @State private var all: [MediaItem] = []
    @State private var genres: [String] = []

    var body: some View {
        let shown = sorted(filtered(all))
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FilterBar(quick: $quick, genre: $genre, decade: $decade, showUHD: true, genres: genres, decades: Array(Set(all.compactMap { FilterBar.decade($0.year) })).sorted(by: >))
                if shown.isEmpty {
                    ContentUnavailableView("No films match", systemImage: "film", description: Text("Try clearing a filter.")).padding(.top, 60)
                } else {
                    ItemGrid(items: shown, fixMatchTarget: $fixMatchTarget)
                }
            }.padding(.vertical, 8)
        }
        .navigationTitle("Films")
        .refreshFromLibrary { all = library.items(kind: .film); genres = library.allGenres(kind: .film) }
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            } label: { Image(systemName: "arrow.up.arrow.down") }
        }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }

    private func filtered(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { f in
            switch quick {
            case .unwatched: if library.watchState(f.itemKey)?.watched == true { return false }
            case .favourites: if !library.isFavourite(f.itemKey) { return false }
            case .uhd: if library.preferredFile(f)?.resolution != "2160p" { return false }
            case .all: break
            }
            if let genre, !f.genres.contains(genre) { return false }
            if let decade, FilterBar.decade(f.year) != decade { return false }
            return true
        }
    }
    private func sorted(_ items: [MediaItem]) -> [MediaItem] {
        switch sort {
        case .title: items
        case .year: items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: items.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .runtime: items.sorted { ($0.runtimeMinutes ?? 0) < ($1.runtimeMinutes ?? 0) }
        case .added: items.sorted { $0.addedAt > $1.addedAt }
        }
    }
}

struct FavouritesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var fixMatchTarget: MediaItem?
    @State private var items: [MediaItem] = []
    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("No favourites yet", systemImage: "heart", description: Text("Long-press any show or film and choose Add to Favourites.")).padding(.top, 80)
            } else {
                ItemGrid(items: items, fixMatchTarget: $fixMatchTarget).padding(.vertical)
            }
        }
        .navigationTitle("Favourites")
        .refreshFromLibrary { items = library.favourites() }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}

struct CollectionsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var newName = ""
    @State private var adding = false
    @State private var collections: [MediaCollection] = []
    @State private var universes: [(name: String, count: Int)] = []
    @State private var series: [(id: Int, name: String, count: Int)] = []
    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("My collections", footer: collections.isEmpty ? "Tap + to make one, then add titles from their menu." : nil) {
                    ForEach(collections, id: \.id) { c in
                        card(c.name, "\(c.itemKeys.count) items", route: .collection(c.id), icon: .mosaic(c.itemKeys.compactMap { library.item($0)?.posterPath }))
                    }
                }
                if !universes.isEmpty {
                    section("Universes", footer: "Studios and franchises, from TMDb's companies and keywords. A universe appears once two of its films are in the library.") {
                        ForEach(universes, id: \.name) { u in
                            let logo = library.logoPath(forUniverse: u.name)
                            card(u.name, "\(u.count) films", route: .universe(u.name), icon: ArtworkURL.logo(logo) != nil ? .logo(logo!) : .mosaic(library.films(inUniverse: u.name).compactMap(\.posterPath)))
                        }
                    }
                }
                if !series.isEmpty {
                    section("Film series", footer: "TMDb's collections: sequels and trilogies with two or more films here.") {
                        ForEach(series, id: \.id) { s in
                            let films = library.films(inCollection: s.id, excluding: "")
                            card(s.name, "\(s.count) films", route: .filmCollection(s.id), icon: films.first?.collectionPosterPath.map { .poster($0) } ?? .mosaic(films.compactMap(\.posterPath)))
                        }
                    }
                }
            }.padding(.vertical)
        }
        .refreshFromLibrary { collections = library.collections(); universes = library.universes(); series = library.filmCollections() }
        .itemNavigation()
        .navigationTitle("Collections")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .alert("New collection", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Create") { if !newName.isEmpty { library.addCollection(named: newName) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func section<Content: View>(_ title: String, footer: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) { content() }.padding(.horizontal)
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
        }
    }

    /// A poster-shaped card, like the film grid, with the grouping's picture and a title and count under it.
    private func card(_ title: String, _ subtitle: String, route: LibraryRoute, icon: CollectionIcon.Kind) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                CollectionIcon(kind: icon, title: title).aspectRatio(2 / 3, contentMode: .fit)
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }
}

/// The picture for a grouping card: a studio logo, the series' own poster, or a mosaic of up to four
/// of its posters, in that order of preference, with the initial as the last resort.
struct CollectionIcon: View {
    enum Kind { case logo(String), poster(String), mosaic([String]) }
    let kind: Kind
    let title: String
    var body: some View {
        Group {
            switch kind {
            case .logo(let path):
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                    AsyncImage(url: ArtworkURL.logo(path, size: .medium)) { image in
                        image.resizable().scaledToFit().padding(10)
                    } placeholder: { ArtworkImage.Placeholder(title: title) }
                }.aspectRatio(2 / 3, contentMode: .fit)
            case .poster(let path):
                ArtworkImage(url: ArtworkURL.poster(path), title: title, aspect: 2 / 3, cornerRadius: 10)
            case .mosaic(let posters):
                let tiles = Array(posters.prefix(4))
                if tiles.isEmpty {
                    ArtworkImage.Placeholder(title: title).aspectRatio(2 / 3, contentMode: .fit)
                } else if tiles.count < 4 {
                    ArtworkImage(url: ArtworkURL.poster(tiles[0]), title: title, aspect: 2 / 3, cornerRadius: 10)
                } else {
                    VStack(spacing: 1) {
                        HStack(spacing: 1) { tile(tiles[0]); tile(tiles[1]) }
                        HStack(spacing: 1) { tile(tiles[2]); tile(tiles[3]) }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func tile(_ path: String) -> some View {
        ArtworkImage(url: ArtworkURL.poster(path), title: title, aspect: 2 / 3, cornerRadius: 0)
    }
}
