import SwiftUI
import MediaCore
import Library
import Metadata

/// Backdrop hero with poster and title, shared by film and show detail.
struct HeroHeader: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let item: MediaItem
    let subtitle: String
    @Binding var fixMatchTarget: MediaItem?

    private var backdropURL: URL? { item.backdropURL }
    @State private var editingArtwork = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: backdropURL, title: item.title + " backdrop", aspect: 16 / 9, cornerRadius: 0)
                .overlay { LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .init(x: 0.5, y: 0.3), endPoint: .bottom) }
            HStack(alignment: .bottom, spacing: 14) {
                ArtworkImage(url: item.posterURL(size: .detail), title: item.title).frame(width: 96).shadow(radius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    if let logo = item.titleLogoURL {
                        // The show's own logo from fanart.tv in place of the typed title, as on a TV box.
                        AsyncImage(url: logo) { image in
                            image.resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 64, alignment: .leading).shadow(radius: 6)
                        } placeholder: { Text(item.title).font(.title2.bold()).lineLimit(2) }
                        .accessibilityLabel(item.title)
                    } else {
                        Text(item.title).font(.title2.bold()).lineLimit(2)
                    }
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
        .task(id: item.itemKey) {
            if let tmdb = settings.tmdb { await library.ensureCastPhotos(for: item, tmdb: tmdb) }
            if let fanart = settings.fanart { await library.fetchExtraArt(for: item, fanart: fanart) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleFavourite(item.itemKey) } label: { Image(systemName: library.isFavourite(item.itemKey) ? "heart.fill" : "heart") }
                Menu {
                    ItemMenuContent(item: item, fixMatchTarget: $fixMatchTarget)
                    if settings.tmdb != nil { Button { editingArtwork = true } label: { Label("Edit artwork…", systemImage: "photo.on.rectangle") } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingArtwork) { ArtworkPickerView(target: .item(item)) }
    }
}

struct ItemMenuContent: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @Binding var fixMatchTarget: MediaItem?
    var body: some View {
        if item.kind == .show {
            Button { item.episodes.forEach { library.setWatched(true, itemKey: $0.itemKey) } } label: { Label("Mark all watched", systemImage: "checkmark.circle") }
            Button { item.episodes.forEach { library.setWatched(false, itemKey: $0.itemKey) } } label: { Label("Mark all unwatched", systemImage: "circle") }
            let seasons = Array(Set(item.episodes.compactMap(\.seasonNumber))).sorted()
            if !seasons.isEmpty {
                Menu { ForEach(seasons, id: \.self) { s in Button("Season \(s)") { downloads.enqueue(season: s, of: item) } } } label: { Label("Download season", systemImage: "arrow.down.circle") }
            }
        } else {
            let watched = library.watchState(item.itemKey)?.watched == true
            Button { library.setWatched(!watched, itemKey: item.itemKey) } label: { Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: "checkmark.circle") }
            if downloads.isDownloaded(item.itemKey) {
                Button(role: .destructive) { downloads.remove(item.itemKey) } label: { Label("Remove download", systemImage: "trash") }
            } else if let e = downloads.entry(for: item.itemKey) {
                Button { downloads.cancel(item.itemKey) } label: { Label(e.state == .downloading ? "Downloading \(Int(e.progress * 100))% · cancel" : "Queued · cancel", systemImage: "xmark.circle") }
            } else {
                Button { downloads.enqueue(item) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        if settings.tmdb != nil { Button { fixMatchTarget = item } label: { Label("Fix match", systemImage: "wrench.and.screwdriver") } }
        Menu("Add to collection") {
            ForEach(library.collections(), id: \.id) { c in
                Button { library.toggle(item.itemKey, in: c) } label: { Label(c.name, systemImage: c.itemKeys.contains(item.itemKey) ? "checkmark" : "rectangle.stack") }
            }
        }
        Divider()
        Button(role: .destructive) { try? library.hide(item); dismiss() } label: { Label("Hide from library", systemImage: "eye.slash") }
    }
}

struct Facts: View {
    let facts: [(String, Color?)]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                Text(f.0).font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator)))
                    .foregroundStyle(f.1 ?? .secondary)
            }
        }
    }
}

struct CastRow: View {
    let names: [String]
    /// TMDb profile paths parallel to `names`; "" or missing falls back to the initial.
    var profiles: [String] = []
    /// TMDb person ids parallel to `names`; 0 or missing means look the person up by name.
    var ids: [Int] = []
    var body: some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                            let profile = i < profiles.count ? profiles[i] : ""
                            NavigationLink(value: LibraryRoute.person(PersonRef(id: i < ids.count ? ids[i] : 0, name: n, profilePath: profile))) {
                            VStack(spacing: 4) {
                                if !profile.isEmpty {
                                    ArtworkImage(url: ArtworkURL.profile(profile), title: n, aspect: 1, cornerRadius: 28).frame(width: 56, height: 56).clipShape(Circle())
                                } else {
                                    ArtworkImage.Placeholder(title: n).frame(width: 56, height: 56).clipShape(Circle())
                                }
                                Text(n).font(.caption2).foregroundStyle(.secondary).frame(width: 72).lineLimit(2).multilineTextAlignment(.center)
                            }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Film

struct FilmDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerCoordinator
    let film: MediaItem
    @State private var fixMatchTarget: MediaItem?
    /// Films TMDb lists in the same collection that are not in the library, by title and year.
    @State private var missingFromCollection: [String] = []

    var body: some View {
        // Fix Match re-points the files and deletes this object; the page under the sheet must not
        // touch a deleted model (SwiftData traps on any property read). Show a stub until it pops.
        if film.isDeleted || film.pendingDeletion {
            ContentUnavailableView("Rematched", systemImage: "arrow.triangle.2.circlepath", description: Text("This title was matched to a different entry. Go back and open it again."))
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        let ws = library.watchState(film.itemKey)
        let file = library.preferredFile(film)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeroHeader(item: film, subtitle: [film.year.map(String.init), film.runtimeMinutes.map { "\($0) min" }, film.genres.prefix(2).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), fixMatchTarget: $fixMatchTarget)
                HStack(spacing: 8) {
                    Button { player.play(film, file: file, settings: settings) } label: {
                        Label(ws?.isInProgress == true ? "Resume at \(MediaFormat.clock(ws!.position))" : "Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    if ws?.isInProgress == true {
                        Button("Start over") { player.play(film, file: file, fromStart: true, settings: settings) }.buttonStyle(.bordered).controlSize(.large)
                    }
                }.padding(.horizontal)
                Facts(facts: [
                    film.rating.map { ("★ \(String(format: "%.1f", $0))", nil) },
                    file?.resolution.map { ($0, nil) },
                    file.map { (($0.fileName as NSString).pathExtension.uppercased(), nil) },
                    ws?.watched == true ? ("Watched", .green) : nil,
                    film.confidence == .autoLow ? ("Low-confidence match", .yellow) : nil,
                ].compactMap { $0 }).padding(.horizontal)
                if let o = film.overview { Text(o).font(.subheadline).padding(.horizontal) }
                CastRow(names: film.cast, profiles: film.castProfiles, ids: film.castIDs).padding(.horizontal)
                if let cid = film.collectionID {
                    let others = library.films(inCollection: cid, excluding: film.itemKey)
                    if !others.isEmpty {
                        ItemRow(title: film.collectionName ?? "Collection", items: others, subtitle: { $0.year.map(String.init) ?? "" }, fixMatchTarget: $fixMatchTarget)
                    }
                    if !missingFromCollection.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if others.isEmpty { Text(film.collectionName ?? "Collection").font(.headline) }
                            Text("Not in your library: " + missingFromCollection.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal)
                    }
                }
                let universes = Universes.universes(studios: film.studios, keywords: film.keywords)
                if !universes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Text("Part of").font(.subheadline).foregroundStyle(.secondary)
                            ForEach(universes, id: \.self) { u in
                                NavigationLink(value: LibraryRoute.universe(u)) { FilterBar.Chip(text: u, on: false) {} }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
                if film.files.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Versions").font(.headline); Spacer(); Text(film.preferredFileID == nil ? "Best quality plays · tap to choose" : "Your choice is remembered").font(.caption).foregroundStyle(.secondary) }
                        ForEach(film.files, id: \.id) { f in
                            Button { library.setPreferredFile(f, for: film) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text([f.resolution, f.qualityTags.first { ["hevc", "x265", "x264", "av1", "h264"].contains($0) }?.uppercased(), (f.fileName as NSString).pathExtension.uppercased()].compactMap { $0 }.joined(separator: " · ")).font(.subheadline.weight(.semibold))
                                        Text("\(MediaFormat.bytes(f.size)) · \(f.source?.name ?? "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if f.id == file?.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .padding(10).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal)
                }
                if let file {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("File").font(.headline)
                        LabeledContent("Path", value: file.relativePath).font(.footnote).lineLimit(2)
                        LabeledContent("Size", value: MediaFormat.bytes(file.size)).font(.footnote)
                        LabeledContent("Source", value: file.source?.name ?? "—").font(.footnote)
                        if let v = file.videoCodec { LabeledContent("Video", value: [file.resolution, v].compactMap { $0 }.joined(separator: " · ")).font(.footnote) }
                        if let a = file.audioSummary { LabeledContent("Audio", value: a).font(.footnote) }
                        if let s = file.subtitleSummary { LabeledContent("Embedded subtitles", value: s).font(.footnote) }
                        if let d = file.duration, d > 0 { LabeledContent("Runtime", value: MediaFormat.clock(d)).font(.footnote) }
                        if !file.sidecars.isEmpty { LabeledContent("Subtitles", value: "\(file.sidecars.count) sidecar file\(file.sidecars.count == 1 ? "" : "s")").font(.footnote) }
                    }.padding(.horizontal)
                }
            }.padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
        .task(id: film.itemKey) {
            guard let tmdb = settings.tmdb else { return }
            await library.ensureCollection(for: film, tmdb: tmdb)
            guard let cid = film.collectionID, let detail = try? await tmdb.collection(id: cid) else { return }
            let have = Set(library.items(kind: .film).compactMap(\.tmdbID))
            missingFromCollection = detail.parts.filter { !have.contains($0.id) && $0.releaseDate.map { !$0.isEmpty } == true }
                .sorted { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
                .map { $0.title + ($0.releaseDate.map { " (\($0.prefix(4)))" } ?? "") }
        }
    }
}

// MARK: - Show

struct ShowDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var downloads: DownloadManager
    let show: MediaItem
    var initialSeason: Int? = nil
    @State private var season: Int?
    @State private var fixMatchTarget: MediaItem?
    /// Computed off the render path: sorting every episode and fetching a watch state per row on each
    /// render, on every store publish, made the season list crawl.
    @State private var seasons: [Int] = []
    @State private var episodesBySeason: [Int: [MediaItem]] = [:]
    @State private var states: [String: WatchState] = [:]
    @State private var next: MediaItem?
    @State private var unwatched = 0
    @State private var refreshTask: Task<Void, Never>?

    private var selected: Int { season ?? initialSeason ?? next?.seasonNumber ?? seasons.first ?? 1 }
    private var episodes: [MediaItem] { episodesBySeason[selected] ?? [] }

    private func refresh() {
        let eps = show.episodes
        seasons = Array(Set(eps.compactMap(\.seasonNumber))).sorted()
        episodesBySeason = Dictionary(grouping: eps, by: { $0.seasonNumber ?? 0 }).mapValues { $0.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) } }
        states = library.watchStates(for: eps.map(\.itemKey))
        next = library.nextEpisode(of: show)
        unwatched = eps.filter { states[$0.itemKey]?.watched != true }.count
    }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    var body: some View {
        // Fix Match re-points the files and deletes this object; the page under the sheet must not
        // touch a deleted model (SwiftData traps on any property read). Show a stub until it pops.
        if show.isDeleted || show.pendingDeletion {
            ContentUnavailableView("Rematched", systemImage: "arrow.triangle.2.circlepath", description: Text("This title was matched to a different entry. Go back and open it again."))
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeroHeader(item: show, subtitle: [show.year.map(String.init), show.seasonsLabel, show.genres.prefix(2).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), fixMatchTarget: $fixMatchTarget)
                if let next {
                    Button { player.play(next, settings: settings) } label: {
                        Label("Play \(next.episodeCode ?? "")", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
                }
                Facts(facts: [
                    show.rating.map { ("★ \(String(format: "%.1f", $0))", nil) },
                    ("\(unwatched) unwatched", nil),
                    show.confidence == .autoLow ? ("Low-confidence match", .yellow) : nil,
                ].compactMap { $0 }).padding(.horizontal)
                if let o = show.overview { Text(o).font(.subheadline).padding(.horizontal) }
                CastRow(names: show.cast, profiles: show.castProfiles, ids: show.castIDs).padding(.horizontal)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Episodes").font(.headline).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(seasons, id: \.self) { s in FilterBar.Chip(text: "Season \(s)", on: s == selected) { season = s } }
                        }.padding(.horizontal)
                    }
                    ForEach(episodes, id: \.itemKey) { ep in
                        EpisodeRow(episode: ep, state: states[ep.itemKey], downloaded: downloads.isDownloaded(ep.itemKey), downloading: downloads.entry(for: ep.itemKey)?.progress).padding(.horizontal)
                            .onTapGesture { player.play(ep, settings: settings) }
                            .contextMenu {
                                let watched = states[ep.itemKey]?.watched == true
                                Button { library.setWatched(!watched, itemKey: ep.itemKey) } label: { Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: "checkmark.circle") }
                                Button { player.play(ep, fromStart: true, settings: settings) } label: { Label("Play from start", systemImage: "gobackward") }
                                if downloads.isDownloaded(ep.itemKey) {
                                    Button(role: .destructive) { downloads.remove(ep.itemKey) } label: { Label("Remove download", systemImage: "trash") }
                                } else if downloads.entry(for: ep.itemKey) != nil {
                                    Button { downloads.cancel(ep.itemKey) } label: { Label("Cancel download", systemImage: "xmark.circle") }
                                } else {
                                    Button { downloads.enqueue(ep) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                }
                            }
                    }
                }
            }.padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onReceive(library.objectWillChange) { _ in scheduleRefresh() }
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}

struct EpisodeRow: View {
    let episode: MediaItem
    /// Handed in by the show page, which fetches all of a show's states in one query.
    var state: WatchState? = nil
    var downloaded = false
    /// Progress 0…1 while a download is in flight.
    var downloading: Double? = nil
    var body: some View {
        let ws = state
        HStack(alignment: .top, spacing: 12) {
            ArtworkImage(url: ArtworkURL.still(episode.stillPath), title: episode.title, aspect: 16 / 9, cornerRadius: 8).frame(width: 120)
                .overlay(alignment: .topLeading) { if ws?.watched == true { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.black).padding(4).background(.green, in: Circle()).padding(6) } }
                .overlay(alignment: .topTrailing) {
                    if downloaded { Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.white, .blue).padding(6) }
                    else if let p = downloading { ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).tint(.white).padding(6) }
                }
                .overlay(alignment: .bottom) {
                    if let p = ws?.progress, ws?.isInProgress == true {
                        GeometryReader { g in Rectangle().fill(.black.opacity(0.45)).overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: g.size.width * p) } }.frame(height: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(episode.episodeNumber ?? 0). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([episode.runtimeMinutes.map { "\($0) min" }, ws?.isInProgress == true ? MediaFormat.minutesLeft(ws!.duration - ws!.position) : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let o = episode.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Minimal wrapping layout for fact chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}
