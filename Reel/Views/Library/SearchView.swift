import SwiftUI
import MediaCore
import Library

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var fixMatchTarget: MediaItem?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
    // Computed when the query or the library changes, not on every render.
    @State private var results: [MediaItem] = []
    @State private var people: [String] = []

    private func runSearch() {
        results = library.search(query)
        people = query.count >= 2 ? Array(Set((library.items(kind: .film) + library.items(kind: .show)).flatMap(\.cast).filter { $0.localizedCaseInsensitiveContains(query) })).sorted() : []
    }

    var body: some View {
        let shows = results.filter { $0.kind == .show }
        let films = results.filter { $0.kind == .film }
        let episodes = results.filter { $0.kind == .episode }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if query.isEmpty {
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            ForEach(recent, id: \.self) { r in Button { query = r } label: { Label(r, systemImage: "clock").foregroundStyle(.primary) } }
                        }.padding(.horizontal)
                    }
                } else if results.isEmpty && people.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 60)
                } else {
                    ItemRow(title: "Shows", items: shows, fixMatchTarget: $fixMatchTarget)
                    ItemRow(title: "Films", items: films, fixMatchTarget: $fixMatchTarget)
                    ItemRow(title: "Episodes", items: episodes, wide: true, subtitle: { "\($0.show?.title ?? "") · \($0.episodeCode ?? "")" }, fixMatchTarget: $fixMatchTarget)
                    if !people.isEmpty { CastRow(names: Array(people.prefix(20))).padding(.horizontal) }
                }
            }.padding(.vertical)
        }
        .onChange(of: query) { _, _ in runSearch() }
        .refreshFromLibrary { runSearch() }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Shows, films, episodes, people")
        .onSubmit(of: .search) {
            var r = recent.filter { $0 != query }; r.insert(query, at: 0)
            recentRaw = r.prefix(6).joined(separator: "\n")
        }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}
