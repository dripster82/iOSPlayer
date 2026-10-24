import SwiftUI
import MediaCore
import Library
import Metadata

/// Edit artwork for a film or show (poster, backdrop, logo from TMDb and fanart.tv), a user
/// collection (one cover, or a collage of up to four ticked posters, from every poster of every
/// title), or a universe / film series (studio logos, title logos, posters and backdrops of its
/// films, single or collage).
struct ArtworkPickerView: View {
    enum Target {
        case item(MediaItem)
        case collection(MediaCollection)
        /// `id` is the key in `GroupArtStore`; `logos` are TMDb studio logo paths; `collectionID` is
        /// the TMDb collection for a film series, whose own posters and backdrops are offered first.
        case group(id: String, name: String, films: [MediaItem], logos: [String], collectionID: Int?)
    }
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var groupArt: GroupArtStore
    @Environment(\.dismiss) private var dismiss
    let target: Target

    enum Slot: String, CaseIterable { case poster = "Poster", backdrop = "Backdrop", logo = "Logo" }
    enum Mode: String, CaseIterable { case single = "One picture", collage = "Collage" }
    struct Candidate: Identifiable, Hashable { var url: URL; var source: String; var id: String { url.absoluteString } }
    struct TitleRow: Identifiable { var item: MediaItem; var candidates: [Candidate]; var id: String { item.itemKey } }

    @State private var slot: Slot = .poster
    @State private var mode: Mode = .single
    @State private var tmdb: [Slot: [Candidate]] = [:]
    @State private var fanart: [Slot: [Candidate]] = [:]
    @State private var titles: [TitleRow] = []
    /// TMDb's images for the collection itself (film series only).
    @State private var collectionPosters: [Candidate] = []
    @State private var collectionBackdrops: [Candidate] = []
    @State private var showFilmImages = false
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isGrouping {
                        Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal)
                        if mode == .collage {
                            Text("Tick up to four posters for the collage · \(collage.count) of 4").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                        }
                    }
                    if case .item = target {
                        Picker("", selection: $slot) { ForEach(Slot.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal)
                    }
                    if mode == .single { currentRow }
                    if loading { HStack { ProgressView(); Text("Fetching artwork…").font(.footnote).foregroundStyle(.secondary) }.padding(.horizontal) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red).padding(.horizontal) }

                    switch target {
                    case .item:
                        section("TMDb", tmdb[slot] ?? [])
                        if settings.fanart != nil { section("fanart.tv", fanart[slot] ?? []) }
                        else if slot != .poster { Text("Add a fanart.tv key in Settings for more logos and backgrounds.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                    case .collection:
                        if titles.isEmpty, !loading { Text("This collection has no titles yet. Add films or shows from their menu, then come back.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                        ForEach(titles) { row in section(row.item.title, row.candidates) }
                    case .group(_, _, _, let logos, let collectionID):
                        if mode == .single {
                            // The group's own identity first: logos, then the collection's own art.
                            let studio = logos.compactMap { ArtworkURL.logo($0, size: .medium) }.map { Candidate(url: $0, source: "tmdb") }
                            let titleLogos = titles.flatMap { $0.item.titleLogoURL.map { [Candidate(url: $0, source: "fanart")] } ?? [] }
                            if !studio.isEmpty || !titleLogos.isEmpty || collectionID == nil {
                                section("Logos", studio + titleLogos, aspect: 16 / 9, logoPanel: true)
                            }
                            if collectionID != nil {
                                section("Collection posters", collectionPosters, aspect: 2 / 3)
                                section("Collection backdrops", collectionBackdrops, aspect: 16 / 9)
                            }
                            DisclosureGroup(isExpanded: $showFilmImages) {
                                section("Film backdrops", titles.compactMap { $0.item.backdropURL(size: .small) }.map { Candidate(url: $0, source: "tmdb") }, aspect: 16 / 9)
                                ForEach(titles) { row in section(row.item.title, row.candidates, aspect: 2 / 3) }
                            } label: {
                                Text("Individual film images").font(.headline)
                            }.padding(.horizontal)
                        } else {
                            ForEach(titles) { row in section(row.item.title, row.candidates, aspect: 2 / 3) }
                        }
                    }
                }.padding(.vertical)
            }
            .navigationTitle("Edit artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { if isGrouping, !collage.isEmpty { mode = .collage } }
        .task { await load() }
    }

    private var isGrouping: Bool { if case .item = target { return false } else { return true } }

    // MARK: - Current state

    private var currentRow: some View {
        HStack(spacing: 12) {
            if let url = currentURL { ArtworkImage(url: url, title: "current", aspect: slotAspect, cornerRadius: 8).frame(height: 70) }
            VStack(alignment: .leading, spacing: 4) {
                Text(hasOverride ? "Your choice" : "Automatic").font(.subheadline.weight(.semibold))
                if hasOverride { Button("Use automatic") { setOverride(nil) }.font(.footnote) }
                else { Text("Tap any picture below to use it instead.").font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
        }.padding(.horizontal)
    }

    private var slotAspect: CGFloat {
        if case .group = target { return 2 / 3 }
        switch slot { case .poster: return 2 / 3; case .backdrop: return 16 / 9; case .logo: return 16 / 9 }
    }

    private var currentURL: URL? {
        switch target {
        case .collection(let c): return c.artworkURL.flatMap(URL.init)
        case .group(let id, _, _, _, _): return groupArt.art(for: id)?.url.flatMap(URL.init)
        case .item(let i): switch slot { case .poster: return i.posterURL(size: .detail); case .backdrop: return i.backdropURL; case .logo: return i.titleLogoURL }
        }
    }
    private var hasOverride: Bool {
        switch target {
        case .collection(let c): return c.artworkURL != nil
        case .group(let id, _, _, _, _): return groupArt.art(for: id)?.url != nil
        case .item(let i): switch slot { case .poster: return i.posterOverrideURL != nil; case .backdrop: return i.backdropOverrideURL != nil; case .logo: return i.logoOverrideURL != nil }
        }
    }
    private var collage: [String] {
        switch target {
        case .collection(let c): return c.collageURLs
        case .group(let id, _, _, _, _): return groupArt.art(for: id)?.collage ?? []
        case .item: return []
        }
    }
    private func isCurrent(_ url: URL) -> Bool { mode == .collage ? collage.contains(url.absoluteString) : currentURL == url }

    // MARK: - Choosing

    private func choose(_ url: URL) {
        if mode == .collage { toggleCollage(url) } else { setOverride(url) }
    }
    private func setOverride(_ url: URL?) {
        switch target {
        case .collection(let c): library.setArtwork(url?.absoluteString, for: c)
        case .group(let id, _, _, _, _): groupArt.set(url.map { GroupArtStore.Art(url: $0.absoluteString) }, for: id)
        case .item(let i):
            let s: LibraryStore.ArtworkSlot = slot == .poster ? .poster : slot == .backdrop ? .backdrop : .logo
            library.setArtwork(url?.absoluteString, slot: s, for: i)
        }
    }
    private func toggleCollage(_ url: URL) {
        var urls = collage
        if let i = urls.firstIndex(of: url.absoluteString) { urls.remove(at: i) }
        else if urls.count < 4 { urls.append(url.absoluteString) }
        else { return }
        switch target {
        case .collection(let c): library.setCollage(urls, for: c)
        case .group(let id, _, _, _, _): groupArt.set(GroupArtStore.Art(url: nil, collage: urls), for: id)
        case .item: break
        }
    }

    // MARK: - Sections

    private func section(_ title: String, _ candidates: [Candidate], aspect: CGFloat? = nil, logoPanel: Bool? = nil) -> some View {
        let shape = mode == .collage ? 2 / 3 : (aspect ?? slotAspect)
        let panel = logoPanel ?? (slot == .logo && mode == .single)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(candidates.count)").font(.headline).padding(.horizontal)
            if candidates.isEmpty, !loading { Text("Nothing here.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: shape < 1 ? 100 : 150), spacing: 10)], spacing: 10) {
                ForEach(candidates) { c in
                    Button { choose(c.url) } label: {
                        ZStack(alignment: .topTrailing) {
                            if panel, mode == .single { RoundedRectangle(cornerRadius: 8).fill(c.source == "fanart" ? Color(white: 0.12) : Color.white) }
                            ArtworkImage(url: c.url, title: "artwork", aspect: shape, cornerRadius: 8)
                                .overlay { if isCurrent(c.url) { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3) } }
                            if mode == .collage, let n = collage.firstIndex(of: c.url.absoluteString) {
                                Text("\(n + 1)").font(.caption.bold()).foregroundStyle(.white).padding(6).background(Color.accentColor, in: Circle()).padding(6)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal)
        }
    }

    // MARK: - Loading

    private func load() async {
        switch target {
        case .item(let item):
            guard let client = settings.tmdb, let id = item.tmdbID else { loading = false; error = "Add a TMDb API key in Settings."; return }
            do {
                let imgs = try await client.images(id: id, isShow: item.kind == .show)
                tmdb[.poster] = (imgs.posters ?? []).prefix(40).compactMap { ArtworkURL.poster($0.filePath, size: .detail) }.map { Candidate(url: $0, source: "tmdb") }
                tmdb[.backdrop] = (imgs.backdrops ?? []).prefix(40).compactMap { ArtworkURL.backdrop($0.filePath, size: .small) }.map { Candidate(url: $0, source: "tmdb") }
                tmdb[.logo] = (imgs.logos ?? []).prefix(40).compactMap { ArtworkURL.logo($0.filePath, size: .medium) }.map { Candidate(url: $0, source: "tmdb") }
            } catch { self.error = error.localizedDescription }
            if let fa = settings.fanart {
                let art: FanartArt?
                if item.kind == .show, let tvdb = item.tvdbID { art = try? await fa.show(tvdbID: tvdb) }
                else if item.kind == .film { art = try? await fa.movie(tmdbID: id) }
                else { art = nil }
                if let art {
                    fanart[.poster] = art.posterURLs.compactMap(URL.init).map { Candidate(url: $0, source: "fanart") }
                    fanart[.backdrop] = art.backgroundURLs.compactMap(URL.init).map { Candidate(url: $0, source: "fanart") }
                    fanart[.logo] = art.logoURLs.compactMap(URL.init).map { Candidate(url: $0, source: "fanart") }
                }
            }
        case .collection(let c):
            await loadTitles(c.itemKeys.compactMap { library.item($0) })
        case .group(_, _, let films, _, let collectionID):
            if let collectionID, let client = settings.tmdb, let imgs = try? await client.collectionImages(id: collectionID) {
                collectionPosters = (imgs.posters ?? []).prefix(30).compactMap { ArtworkURL.poster($0.filePath, size: .detail) }.map { Candidate(url: $0, source: "tmdb") }
                collectionBackdrops = (imgs.backdrops ?? []).prefix(30).compactMap { ArtworkURL.backdrop($0.filePath, size: .small) }.map { Candidate(url: $0, source: "tmdb") }
            }
            await loadTitles(films)
        }
        loading = false
    }

    /// One row per title: its current poster first, then every other poster TMDb holds for it.
    /// Fetched title by title so the first rows appear at once.
    private func loadTitles(_ items: [MediaItem]) async {
        titles = items.map { TitleRow(item: $0, candidates: $0.posterURL(size: .detail).map { [Candidate(url: $0, source: "tmdb")] } ?? []) }
        guard let client = settings.tmdb else { return }
        for (n, item) in items.enumerated() {
            guard let id = item.tmdbID, item.kind != .episode, let imgs = try? await client.images(id: id, isShow: item.kind == .show) else { continue }
            var seen = Set(titles[n].candidates.map(\.id))
            for p in (imgs.posters ?? []).prefix(12) {
                if let url = ArtworkURL.poster(p.filePath, size: .detail), seen.insert(url.absoluteString).inserted {
                    titles[n].candidates.append(Candidate(url: url, source: "tmdb"))
                }
            }
        }
    }
}
