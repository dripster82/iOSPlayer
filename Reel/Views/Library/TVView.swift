import SwiftUI
import MediaCore
import Library

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
    @State private var fixMatchTarget: MediaItem?
    @State private var collections: [MediaCollection] = []
    var body: some View {
        List {
            ForEach(collections, id: \.id) { c in
                NavigationLink {
                    ScrollView { ItemGrid(items: c.itemKeys.compactMap { library.item($0) }, fixMatchTarget: $fixMatchTarget).padding(.vertical) }
                        .navigationTitle(c.name).itemNavigation()
                } label: {
                    HStack {
                        ArtworkImage.Placeholder(title: c.name).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) { Text(c.name).font(.headline); Text("\(c.itemKeys.count) items").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .overlay { if collections.isEmpty { ContentUnavailableView("No collections", systemImage: "rectangle.stack", description: Text("Group films and shows however you like.")) } }
        .refreshFromLibrary { collections = library.collections() }
        .navigationTitle("Collections")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .alert("New collection", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Create") { if !newName.isEmpty { library.addCollection(named: newName) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}
