import SwiftUI
import MediaCore
import Library

struct UniverseView: View {
    @EnvironmentObject private var library: LibraryStore
    let name: String
    @State private var fixMatchTarget: MediaItem?
    @State private var films: [MediaItem] = []
    var body: some View {
        ScrollView {
            if films.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "sparkles", description: Text("Films join a universe from their TMDb studio and keywords.")).padding(.top, 60)
            } else {
                ItemGrid(items: films, fixMatchTarget: $fixMatchTarget).padding(.vertical)
            }
        }
        .navigationTitle(name)
        .refreshFromLibrary { films = library.films(inUniverse: name) }
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}

/// A TMDb film series (sequels, a trilogy): the library's films in it, oldest first.
struct FilmCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    let id: Int
    @State private var fixMatchTarget: MediaItem?
    @State private var films: [MediaItem] = []
    var body: some View {
        ScrollView { ItemGrid(items: films, fixMatchTarget: $fixMatchTarget).padding(.vertical) }
            .navigationTitle(films.first?.collectionName ?? "Collection")
            .refreshFromLibrary { films = library.films(inCollection: id, excluding: "") }
            .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}
