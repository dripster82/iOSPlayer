import SwiftUI
import MediaCore
import Library

struct UniverseView: View {
    @EnvironmentObject private var library: LibraryStore
    let name: String
    @State private var fixMatchTarget: MediaItem?
    @State private var films: [MediaItem] = []
    @AppStorage("hideWatchedInCollections") private var hideWatched = false
    var body: some View {
        let shown = library.visible(films, hideWatched: hideWatched)
        ScrollView {
            if films.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "sparkles", description: Text("Films join a universe from their TMDb studio and keywords.")).padding(.top, 60)
            } else if shown.isEmpty {
                ContentUnavailableView("All watched", systemImage: "checkmark.circle", description: Text("Everything here is watched. Tap the eye to show it.")).padding(.top, 60)
            } else {
                ItemGrid(items: shown, fixMatchTarget: $fixMatchTarget).padding(.vertical)
            }
        }
        .toolbar { HideWatchedButton() }
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
    @AppStorage("hideWatchedInCollections") private var hideWatched = false
    var body: some View {
        ScrollView { ItemGrid(items: library.visible(films, hideWatched: hideWatched), fixMatchTarget: $fixMatchTarget).padding(.vertical) }
            .toolbar { HideWatchedButton() }
            .navigationTitle(films.first?.collectionName ?? "Collection")
            .refreshFromLibrary { films = library.films(inCollection: id, excluding: "") }
            .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}
