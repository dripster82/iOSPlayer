import SwiftUI
import MediaCore
import Library

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var smart: SmartCollectionStore
    @State private var query = ""
    @State private var fixMatchTarget: MediaItem?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
    // Computed when the query or the library changes, not on every render.
    @State private var results: [MediaItem] = []
    @State private var people: [String] = []
    @State private var groups: [GroupHit] = []

    /// A collection of any kind whose name matches: custom, smart, universe or film series.
    struct GroupHit: Identifiable { var id: String; var title: String; var subtitle: String; var icon: String; var route: LibraryRoute }

    private func runSearch() {
        results = library.search(query)
        let q = query.trimmingCharacters(in: .whitespaces)
        people = q.count >= 2 ? Array(Set((library.items(kind: .film) + library.items(kind: .show)).flatMap(\.cast).filter { $0.localizedCaseInsensitiveContains(q) })).sorted() : []
        guard q.count >= 2 else { groups = []; return }
        var hits: [GroupHit] = []
        for c in library.collections() where c.name.localizedCaseInsensitiveContains(q) {
            hits.append(GroupHit(id: "c:\(c.id)", title: c.name, subtitle: "\(c.itemKeys.count) titles · collection", icon: "rectangle.stack", route: .collection(c.id)))
        }
        for s in smart.all where s.name.localizedCaseInsensitiveContains(q) {
            hits.append(GroupHit(id: "sm:\(s.id)", title: s.name, subtitle: "Smart collection", icon: "sparkles", route: .smart(s.id)))
        }
        for u in library.universes() where u.name.localizedCaseInsensitiveContains(q) {
            hits.append(GroupHit(id: "u:\(u.name)", title: u.name, subtitle: "\(u.count) films · universe", icon: "globe", route: .universe(u.name)))
        }
        for f in library.filmCollections() where f.name.localizedCaseInsensitiveContains(q) {
            hits.append(GroupHit(id: "f:\(f.id)", title: f.name, subtitle: "\(f.count) films · film series", icon: "film.stack", route: .filmCollection(f.id)))
        }
        groups = hits
    }

    var body: some View {
        let shows = results.filter { $0.kind == .show }
        let films = results.filter { $0.kind == .film }
        let episodes = results.filter { $0.kind == .episode }
        let books = results.filter { $0.kind == .audiobook }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if query.isEmpty {
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            ForEach(recent, id: \.self) { r in Button { query = r } label: { Label(r, systemImage: "clock").foregroundStyle(.primary) } }
                        }.padding(.horizontal)
                    }
                } else if results.isEmpty && people.isEmpty && groups.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 60)
                } else {
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Collections").font(.headline)
                            ForEach(groups) { g in
                                NavigationLink(value: g.route) {
                                    HStack(spacing: 12) {
                                        Image(systemName: g.icon).frame(width: 36, height: 36).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading) { Text(g.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(g.subtitle).font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                    ItemRow(title: "Shows", items: shows, fixMatchTarget: $fixMatchTarget)
                    ItemRow(title: "Films", items: films, fixMatchTarget: $fixMatchTarget)
                    ItemRow(title: "Books", items: books, fixMatchTarget: $fixMatchTarget)
                    ItemRow(title: "Episodes", items: episodes, wide: true, subtitle: { "\($0.show?.title ?? "") · \($0.episodeCode ?? "")" }, fixMatchTarget: $fixMatchTarget)
                    if !people.isEmpty { CastRow(names: Array(people.prefix(20))).padding(.horizontal) }
                }
            }.padding(.vertical)
        }
        .onChange(of: query) { _, _ in runSearch() }
        .refreshFromLibrary { runSearch() }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Shows, films, books, episodes, people")
        .onSubmit(of: .search) {
            var r = recent.filter { $0 != query }; r.insert(query, at: 0)
            recentRaw = r.prefix(6).joined(separator: "\n")
        }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}
