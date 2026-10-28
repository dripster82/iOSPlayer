import SwiftUI
import MediaCore
import Library
import Metadata

/// Downloads: what is on this device, as title cards. Films in a grid; shows grouped, with their
/// episodes by season as wide cards. A card opens the title's page; its play button plays the copy
/// straight away. What is still downloading sits at the top.
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmRemoveAll = false
    @State private var removing: Finished?

    private struct Finished: Identifiable, Hashable { let itemKey: String; let bytes: Int64; let title: String; var id: String { itemKey } }
    private struct ShowGroup: Identifiable { let show: MediaItem; let seasons: [(number: Int, episodes: [(MediaItem, Int64)])]; let bytes: Int64; var id: String { show.itemKey } }

    var body: some View {
        let finished = downloads.finished().map { Finished(itemKey: $0.itemKey, bytes: $0.bytes, title: $0.title) }
        let items = Dictionary(uniqueKeysWithValues: finished.compactMap { f in library.item(f.itemKey).map { (f.itemKey, $0) } })
        let films = finished.compactMap { f in items[f.itemKey].flatMap { $0.kind == .film ? ($0, f.bytes) : nil } }
        let shows = groups(of: finished.compactMap { f in items[f.itemKey].flatMap { $0.kind == .episode ? ($0, f.bytes) : nil } })
        let strays = finished.filter { items[$0.itemKey] == nil }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !downloads.active.isEmpty { inProgress }
                if finished.isEmpty && downloads.active.isEmpty {
                    ContentUnavailableView("Nothing downloaded", systemImage: "arrow.down.circle", description: Text("Use Download in a film's or episode's menu to keep a copy on this device. Downloads play even when the NAS is unreachable."))
                        .padding(.top, 60)
                }
                if !films.isEmpty { filmsSection(films) }
                ForEach(shows) { group in showSection(group) }
                if !strays.isEmpty { straysSection(strays) }
            }
            .padding(.vertical)
        }
        .navigationTitle("Downloads")
        .itemNavigation()
        .toolbar {
            if !finished.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text(MediaFormat.bytes(downloads.totalBytes) + " on this device")
                        Button("Remove all downloads", role: .destructive) { confirmRemoveAll = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Remove every download from this device?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
        }
        .confirmationDialog("Remove this download?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { f in
            Button("Remove \(f.title)", role: .destructive) { downloads.remove(f.itemKey) }
        }
        .onAppear { downloads.refresh() }
    }

    // MARK: Sections

    private var inProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Downloading")
            ForEach(downloads.active) { e in
                HStack(spacing: 12) {
                    if let item = library.item(e.itemKey) {
                        ArtworkImage(url: item.kind == .episode ? (ArtworkURL.still(item.stillPath) ?? item.posterURL) : item.posterURL, title: item.title, aspect: item.kind == .episode ? 16 / 9 : 2 / 3, cornerRadius: 6)
                            .frame(width: item.kind == .episode ? 96 : 40)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let s = e.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        switch e.state {
                        case .queued: Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                        case .downloading:
                            ProgressView(value: e.progress)
                            Text("\(MediaFormat.bytes(e.bytes)) of \(MediaFormat.bytes(e.total))").font(.caption).foregroundStyle(.secondary)
                        case .failed(let why):
                            Text(why).font(.caption).foregroundStyle(.red).lineLimit(2)
                            Button("Retry") { downloads.retry(e.itemKey) }.font(.caption)
                        }
                    }
                    Spacer()
                    Button { downloads.cancel(e.itemKey) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
    }

    private func filmsSection(_ films: [(MediaItem, Int64)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Films", detail: "\(films.count) · \(MediaFormat.bytes(films.reduce(0) { $0 + $1.1 }))")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], alignment: .leading, spacing: 18) {
                ForEach(films, id: \.0.itemKey) { film, bytes in
                    card(film, bytes: bytes, wide: false)
                }
            }
            .padding(.horizontal)
        }
    }

    private func showSection(_ group: ShowGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: group.show.itemKey) {
                HStack(spacing: 12) {
                    ArtworkImage(url: group.show.posterURL, title: group.show.title, aspect: 2 / 3, cornerRadius: 6).frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.show.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Text("\(group.seasons.reduce(0) { $0 + $1.episodes.count }) episodes · \(MediaFormat.bytes(group.bytes))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
            ForEach(group.seasons, id: \.number) { season in
                Text(season.number == 0 ? "Specials" : "Season \(season.number)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(season.episodes, id: \.0.itemKey) { episode, bytes in
                            card(episode, bytes: bytes, wide: true).frame(width: 200)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func straysSection(_ strays: [Finished]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header("No longer in the library")
            ForEach(strays) { f in
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(f.title).lineLimit(1)
                    Spacer()
                    Text(MediaFormat.bytes(f.bytes)).font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) { downloads.remove(f.itemKey) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.bold))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal)
    }

    /// A poster (film) or still (episode) card: the card opens the title's page, the play button
    /// plays the copy, and a long press offers both plus removal.
    private func card(_ item: MediaItem, bytes: Int64, wide: Bool) -> some View {
        NavigationLink(value: item.itemKey) {
            PosterCard(item: item, subtitle: wide ? "\(item.episodeCode ?? "") · \(MediaFormat.bytes(bytes))" : "\(item.year.map { "\($0) · " } ?? "")\(MediaFormat.bytes(bytes))", wide: wide)
                .overlay(alignment: wide ? .center : .bottomLeading) {
                    Button { player.play(item, settings: settings) } label: {
                        Image(systemName: "play.fill").font(wide ? .title2 : .footnote).foregroundStyle(.white)
                            .padding(wide ? 12 : 7).background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(wide ? 0 : 6)
                    .offset(y: wide ? -12 : -24)   // above the title lines
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { player.play(item, settings: settings) } label: { Label("Play", systemImage: "play.fill") }
            NavigationLink(value: item.itemKey) { Label("Details", systemImage: "info.circle") }
            Button(role: .destructive) { removing = Finished(itemKey: item.itemKey, bytes: bytes, title: item.title) } label: { Label("Remove download", systemImage: "trash") }
        }
    }

    private func groups(of episodes: [(MediaItem, Int64)]) -> [ShowGroup] {
        let byShow = Dictionary(grouping: episodes.filter { $0.0.show != nil }) { $0.0.show!.itemKey }
        return byShow.values.compactMap { eps -> ShowGroup? in
            guard let show = eps.first?.0.show else { return nil }
            let bySeason = Dictionary(grouping: eps) { $0.0.seasonNumber ?? 0 }
            let seasons = bySeason.keys.sorted().map { n in
                (number: n, episodes: bySeason[n]!.sorted { ($0.0.episodeNumber ?? 0) < ($1.0.episodeNumber ?? 0) })
            }
            return ShowGroup(show: show, seasons: seasons, bytes: eps.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.show.title.localizedCaseInsensitiveCompare($1.show.title) == .orderedAscending }
    }
}
