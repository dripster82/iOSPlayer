import SwiftUI
import MediaCore
import Library

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var smart: SmartCollectionStore
    @State private var query = ""
    /// The field sits in the page under the title, like every other page's content, and takes
    /// focus on arrival. The system search bar would replace the title with a Cancel button.
    @FocusState private var fieldFocused: Bool
    @State private var fixMatchTarget: MediaItem?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
    // Computed when the query or the library changes, not on every render.
    @State private var results: [MediaItem] = []
    /// Names with the profile path and TMDb id the cast lists carry, so the row shows faces.
    @State private var people: [(name: String, profile: String, id: Int)] = []
    @State private var groups: [GroupHit] = []

    /// A collection of any kind whose name matches: custom, smart, universe or film series.
    struct GroupHit: Identifiable { var id: String; var title: String; var subtitle: String; var icon: String; var route: LibraryRoute }

    private func remember(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var r = recent.filter { $0 != q }; r.insert(q, at: 0)
        recentRaw = r.prefix(6).joined(separator: "\n")
    }

    private func runSearch() {
        results = library.search(query)
        let q = query.trimmingCharacters(in: .whitespaces)
        var found: [String: (profile: String, id: Int)] = [:]
        if q.count >= 2 {
            for item in library.items(kind: .film) + library.items(kind: .show) {
                for (i, name) in item.cast.enumerated() where name.localizedCaseInsensitiveContains(q) {
                    let profile = i < item.castProfiles.count ? item.castProfiles[i] : ""
                    let id = i < item.castIDs.count ? item.castIDs[i] : 0
                    // Keep the first entry that has a picture or an id over one with neither.
                    if let have = found[name], !have.profile.isEmpty || have.id != 0 { continue }
                    found[name] = (profile, id)
                }
            }
        }
        people = found.keys.sorted().map { (name: $0, profile: found[$0]!.profile, id: found[$0]!.id) }
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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Shows, films, books, episodes, people", text: $query)
                        .focused($fieldFocused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { remember(query) }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
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
                    ItemRow(title: "Episodes", items: episodes, wide: true, subtitle: { [$0.episodeCode, $0.title].compactMap { $0 }.joined(separator: " · ") }, fixMatchTarget: $fixMatchTarget)
                    if !people.isEmpty {
                        let shown = people.prefix(20)
                        CastRow(names: shown.map(\.name), profiles: shown.map(\.profile), ids: shown.map(\.id)).padding(.horizontal)
                    }
                }
            }.padding(.vertical)
        }
        .onChange(of: query) { _, _ in runSearch() }
        .refreshFromLibrary { runSearch() }
        .navigationTitle("Search")
        .onAppear { fieldFocused = true }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}
