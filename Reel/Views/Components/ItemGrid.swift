import SwiftUI
import Library

/// Adaptive poster grid: 3 across on phone, more on iPad.
struct ItemGrid: View {
    let items: [MediaItem]
    @Binding var fixMatchTarget: MediaItem?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 10)], spacing: 14) {
            ForEach(items.filter { !$0.isDeleted }, id: \.itemKey) { item in
                NavigationLink(value: item.itemKey) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .itemContextMenu(item, fixMatchTarget: $fixMatchTarget)
            }
        }
        .padding(.horizontal)
    }
}

/// Horizontal row of cards for Home.
struct ItemRow: View {
    let title: String
    let items: [MediaItem]
    var wide = false
    var subtitle: ((MediaItem) -> String)? = nil
    var seeAll: (() -> Void)? = nil
    /// When set, tapping a card does this (e.g. resume playback) instead of navigating to the detail page.
    var onTap: ((MediaItem) -> Void)? = nil
    /// The Continue Watching row: its long-press menu removes from the row rather than hiding the title.
    var isContinueWatching = false
    @Binding var fixMatchTarget: MediaItem?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let seeAll { Button("See all", action: seeAll).font(.subheadline) }
                }.padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(items.filter { !$0.isDeleted }, id: \.itemKey) { item in
                            Group {
                                if let onTap {
                                    Button { onTap(item) } label: { PosterCard(item: item, subtitle: subtitle?(item), wide: wide).frame(width: wide ? 200 : 118) }
                                } else {
                                    NavigationLink(value: item.itemKey) { PosterCard(item: item, subtitle: subtitle?(item), wide: wide).frame(width: wide ? 200 : 118) }
                                }
                            }
                            .buttonStyle(.plain)
                            .itemContextMenu(item, fixMatchTarget: $fixMatchTarget, inContinueWatching: isContinueWatching)
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }
}

/// Library screens pushed by value. A screen pushed with the view-based `NavigationLink { … }`
/// cannot resolve value-based links inside it (SwiftUI pushes it outside the stack's path), which is
/// why posters inside a custom collection did nothing. Everything that contains posters is pushed
/// by value through this route, registered wherever `itemNavigation()` is.
enum LibraryRoute: Hashable {
    case favourites
    case collections
    case collection(UUID)
    case settings
    case needsReview
    case person(PersonRef)
    case universe(String)
    case filmCollection(Int)
    case smart(UUID)
}

/// Who was tapped in a cast row. The TMDb id is 0 for cast recorded before ids were kept; the
/// person page then finds them by name.
struct PersonRef: Hashable {
    var id: Int
    var name: String
    var profilePath: String
}

struct LibraryRouteDestination: View {
    @EnvironmentObject private var library: LibraryStore
    let route: LibraryRoute
    @State private var fixMatchTarget: MediaItem?
    @AppStorage("hideWatchedInCollections") private var hideWatched = false
    var body: some View {
        switch route {
        case .favourites: FavouritesView()
        case .collections: CollectionsView()
        case .settings: SettingsView()
        case .needsReview: NeedsReviewView()
        case .person(let p): PersonView(person: p)
        case .universe(let name): UniverseView(name: name)
        case .filmCollection(let id): FilmCollectionView(id: id)
        case .smart(let id): SmartCollectionView(id: id)
        case .collection(let id):
            if let c = library.collections().first(where: { $0.id == id }) {
                ScrollView { ItemGrid(items: library.visible(c.itemKeys.compactMap { library.item($0) }, hideWatched: hideWatched), fixMatchTarget: $fixMatchTarget).padding(.vertical) }
                    .toolbar { HideWatchedButton() }
                    .navigationTitle(c.name)
                    .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
            } else {
                ContentUnavailableView("Collection removed", systemImage: "rectangle.stack")
            }
        }
    }
}

/// Resolves an itemKey pushed via NavigationLink(value:) to the right detail view. After Fix Match
/// the old key points at a hidden orphan; the page follows it to the title it was rematched to.
struct ItemDestination: View {
    @EnvironmentObject private var library: LibraryStore
    let key: String
    var body: some View {
        if let item = library.item(key).flatMap({ $0.pendingDeletion ? library.rematched[key].flatMap(library.item) : $0 }) {
            switch item.kind {
            case .show: ShowDetailView(show: item)
            case .film: FilmDetailView(film: item)
            case .episode: if let show = item.show { ShowDetailView(show: show, initialSeason: item.seasonNumber) } else { Text(item.title) }
            }
        } else {
            ContentUnavailableView("Not in library", systemImage: "questionmark.folder")
        }
    }
}

extension View {
    /// Attach once per NavigationStack so `NavigationLink(value: itemKey)` works everywhere beneath.
    func itemNavigation() -> some View {
        navigationDestination(for: String.self) { ItemDestination(key: $0) }
            .navigationDestination(for: LibraryRoute.self) { LibraryRouteDestination(route: $0) }
    }
}
