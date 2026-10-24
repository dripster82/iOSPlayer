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
            NavigationLink(value: LibraryRoute.collections) { Image(systemName: "rectangle.stack") }
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
    @EnvironmentObject private var groupArt: GroupArtStore
    @EnvironmentObject private var smart: SmartCollectionStore
    @State private var newName = ""
    @State private var adding = false
    @State private var addingSmart = false
    @State private var smartCards: [Card] = []
    /// Built once per library change, off the render path: the old body re-fetched and re-grouped
    /// every film for every card on every redraw, which made the screen crawl on a big library.
    @State private var mine: [Card] = []
    @State private var universes: [Card] = []
    @State private var series: [Card] = []
    @State private var editing: EditTarget?
    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 10)]

    struct Card: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var route: LibraryRoute
        var icon: CollectionIcon.Kind
        var editTarget: ArtworkPickerView.Target
        var hasCustomArt: Bool
        var editable = true
    }
    struct EditTarget: Identifiable { var id: String; var target: ArtworkPickerView.Target }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("My collections", cards: mine, footer: mine.isEmpty ? "Tap + to make one, then add titles from their menu." : nil)
                section("Smart collections", cards: smartCards, footer: smartCards.isEmpty ? "Saved filters that fill themselves: unwatched Marvel, films under 100 minutes, added this month. Use + to make one." : nil)
                if !universes.isEmpty {
                    section("Universes", cards: universes, footer: "Studios and franchises, from TMDb's companies and keywords. A universe appears once two of its films are in the library.")
                }
                if !series.isEmpty {
                    section("Film series", cards: series, footer: "TMDb's collections: sequels and trilogies with two or more films here.")
                }
            }.padding(.vertical)
        }
        .refreshFromLibrary { rebuild() }
        .onReceive(groupArt.$version) { _ in rebuild() }
        .onReceive(smart.$all) { _ in rebuild() }
        .itemNavigation()
        .navigationTitle("Collections")
        .toolbar {
            Menu {
                Button { adding = true } label: { Label("New collection", systemImage: "rectangle.stack.badge.plus") }
                Button { addingSmart = true } label: { Label("New smart collection", systemImage: "sparkles") }
            } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $addingSmart) { SmartCollectionEditor(rule: SmartCollection(name: ""), isNew: true) }
        .sheet(item: $editing) { ArtworkPickerView(target: $0.target) }
        .alert("New collection", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Create") { if !newName.isEmpty { library.addCollection(named: newName) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func rebuild() {
        mine = library.collections().map { c in
            let posters = c.itemKeys.compactMap { library.item($0)?.posterURL }
            let icon: CollectionIcon.Kind = c.artworkURL.flatMap(URL.init).map { .url($0) }
                ?? .mosaicURLs(c.collageURLs.isEmpty ? posters : c.collageURLs.compactMap(URL.init))
            return Card(id: "c:\(c.id)", title: c.name, subtitle: "\(c.itemKeys.count) items", route: .collection(c.id), icon: icon,
                        editTarget: .collection(c), hasCustomArt: c.artworkURL != nil || !c.collageURLs.isEmpty)
        }
        smartCards = smart.all.map { r in
            let matches = r.matches(in: library)
            return Card(id: "sm:\(r.id)", title: r.name, subtitle: "\(matches.count) titles", route: .smart(r.id),
                        icon: .mosaicURLs(matches.prefix(4).compactMap(\.posterURL)), editTarget: .collection(MediaCollection(name: "")), hasCustomArt: false, editable: false)
        }
        let index = library.groupIndex()
        universes = index.universes.map { g in
            let id = "u:\(g.name)"
            let automatic: CollectionIcon.Kind = ArtworkURL.logo(g.logoPath) != nil ? .logo(g.logoPath!)
                : g.fanartLogoURL.flatMap(URL.init).map { .titleLogo($0) } ?? .mosaicURLs(g.films.compactMap(\.posterURL))
            return Card(id: id, title: g.name, subtitle: "\(g.films.count) films", route: .universe(g.name), icon: custom(id) ?? automatic,
                        editTarget: .group(id: id, name: g.name, films: g.films, logos: g.logoPaths, collectionID: nil), hasCustomArt: groupArt.art(for: id) != nil)
        }
        series = index.series.map { s in
            let id = "s:\(s.id)"
            let automatic: CollectionIcon.Kind = s.group.posterPath.map { .poster($0) } ?? .mosaicURLs(s.group.films.compactMap(\.posterURL))
            return Card(id: id, title: s.group.name, subtitle: "\(s.group.films.count) films", route: .filmCollection(s.id), icon: custom(id) ?? automatic,
                        editTarget: .group(id: id, name: s.group.name, films: s.group.films, logos: [], collectionID: s.id), hasCustomArt: groupArt.art(for: id) != nil)
        }
    }

    /// The user's pick for a universe or series, if any.
    private func custom(_ id: String) -> CollectionIcon.Kind? {
        guard let art = groupArt.art(for: id) else { return nil }
        if let url = art.url.flatMap(URL.init) { return .url(url) }
        if !art.collage.isEmpty { return .mosaicURLs(art.collage.compactMap(URL.init)) }
        return nil
    }

    private func section(_ title: String, cards: [Card], footer: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(cards) { card in
                    NavigationLink(value: card.route) {
                        VStack(alignment: .leading, spacing: 6) {
                            CollectionIcon(kind: card.icon, title: card.title).aspectRatio(2 / 3, contentMode: .fit)
                            Text(card.title).font(.footnote.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                            Text(card.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    .contextMenu {
                        if card.editable { Button { editing = EditTarget(id: card.id, target: card.editTarget) } label: { Label("Edit artwork…", systemImage: "photo.on.rectangle") } }
                        if card.hasCustomArt {
                            Button { resetArt(card) } label: { Label("Use automatic artwork", systemImage: "arrow.uturn.backward") }
                        }
                    }
                }
            }.padding(.horizontal)
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
        }
    }

    private func resetArt(_ card: Card) {
        switch card.editTarget {
        case .collection(let c): library.setArtwork(nil, for: c); library.setCollage([], for: c)
        case .group(let id, _, _, _, _): groupArt.set(nil, for: id)
        case .item: break
        }
    }
}

/// The picture for a grouping card: a studio logo, the series' own poster, or a mosaic of up to four
/// of its posters, in that order of preference, with the initial as the last resort.
struct CollectionIcon: View {
    enum Kind { case logo(String), titleLogo(URL), poster(String), url(URL), mosaic([String]), mosaicURLs([URL]) }
    let kind: Kind
    let title: String
    var body: some View {
        Group {
            switch kind {
            case .logo(let path):
                // TMDb's company logos are drawn for a white page (many are black on transparent),
                // so the panel is white in both colour schemes.
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color.white, Color(white: 0.92)], startPoint: .top, endPoint: .bottom))
                    AsyncImage(url: ArtworkURL.logo(path, size: .full)) { image in
                        image.resizable().scaledToFit().padding(12)
                    } placeholder: { ArtworkImage.Placeholder(title: title) }
                }.aspectRatio(2 / 3, contentMode: .fit)
            case .titleLogo(let url):
                // fanart.tv title logos are made for dark backgrounds.
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit().padding(12)
                    } placeholder: { ArtworkImage.Placeholder(title: title) }
                }.aspectRatio(2 / 3, contentMode: .fit)
            case .poster(let path):
                ArtworkImage(url: ArtworkURL.poster(path), title: title, aspect: 2 / 3, cornerRadius: 10)
            case .url(let url):
                ArtworkImage(url: url, title: title, aspect: 2 / 3, cornerRadius: 10)
            case .mosaic(let posters):
                mosaic(posters.compactMap { ArtworkURL.poster($0) })
            case .mosaicURLs(let urls):
                mosaic(urls)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func mosaic(_ urls: [URL]) -> some View {
        let tiles = Array(urls.prefix(4))
        if tiles.isEmpty {
            ArtworkImage.Placeholder(title: title).aspectRatio(2 / 3, contentMode: .fit)
        } else if tiles.count < 4 {
            ArtworkImage(url: tiles[0], title: title, aspect: 2 / 3, cornerRadius: 10)
        } else {
            VStack(spacing: 1) {
                HStack(spacing: 1) { tile(tiles[0]); tile(tiles[1]) }
                HStack(spacing: 1) { tile(tiles[2]); tile(tiles[3]) }
            }
        }
    }
    private func tile(_ url: URL) -> some View {
        ArtworkImage(url: url, title: title, aspect: 2 / 3, cornerRadius: 0)
    }
}
