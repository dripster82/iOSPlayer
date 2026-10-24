import SwiftUI
import MediaCore
import Library

/// Chips across the top of Films: Marvel, Pixar, Star Wars… each a grid of the library's films in
/// that universe. Only universes with two or more films are shown.
struct UniversesRow: View {
    let universes: [(name: String, count: Int)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Universes").font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(universes, id: \.name) { u in
                        NavigationLink(value: LibraryRoute.universe(u.name)) {
                            HStack(spacing: 6) {
                                Text(u.name).font(.footnote.weight(.medium))
                                Text("\(u.count)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.1), in: Capsule())
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
        }
    }
}

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
