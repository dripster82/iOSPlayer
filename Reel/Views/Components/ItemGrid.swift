import SwiftUI
import Library

/// Adaptive poster grid: 3 across on phone, more on iPad.
struct ItemGrid: View {
    let items: [MediaItem]
    @Binding var fixMatchTarget: MediaItem?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 10)], spacing: 14) {
            ForEach(items, id: \.itemKey) { item in
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
                        ForEach(items, id: \.itemKey) { item in
                            NavigationLink(value: item.itemKey) {
                                PosterCard(item: item, subtitle: subtitle?(item), wide: wide).frame(width: wide ? 200 : 118)
                            }
                            .buttonStyle(.plain)
                            .itemContextMenu(item, fixMatchTarget: $fixMatchTarget)
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }
}

/// Resolves an itemKey pushed via NavigationLink(value:) to the right detail view.
struct ItemDestination: View {
    @EnvironmentObject private var library: LibraryStore
    let key: String
    var body: some View {
        if let item = library.item(key) {
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
    }
}
