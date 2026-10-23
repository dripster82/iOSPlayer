import SwiftUI
import MediaCore
import Library
import Metadata

/// Backdrop hero with poster and title, shared by film and show detail.
struct HeroHeader: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    let subtitle: String
    @Binding var fixMatchTarget: MediaItem?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: ArtworkURL.backdrop(item.backdropPath), title: item.title + " backdrop", aspect: 16 / 9, cornerRadius: 0)
                .overlay { LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .init(x: 0.5, y: 0.3), endPoint: .bottom) }
            HStack(alignment: .bottom, spacing: 14) {
                ArtworkImage(url: ArtworkURL.poster(item.posterPath, size: .detail), title: item.title).frame(width: 96).shadow(radius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.title2.bold()).lineLimit(2)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleFavourite(item.itemKey) } label: { Image(systemName: library.isFavourite(item.itemKey) ? "heart.fill" : "heart") }
                Menu { ItemMenuContent(item: item, fixMatchTarget: $fixMatchTarget) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

struct ItemMenuContent: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @Binding var fixMatchTarget: MediaItem?
    var body: some View {
        if item.kind == .show {
            Button { item.episodes.forEach { library.setWatched(true, itemKey: $0.itemKey) } } label: { Label("Mark all watched", systemImage: "checkmark.circle") }
            Button { item.episodes.forEach { library.setWatched(false, itemKey: $0.itemKey) } } label: { Label("Mark all unwatched", systemImage: "circle") }
        } else {
            let watched = library.watchState(item.itemKey)?.watched == true
            Button { library.setWatched(!watched, itemKey: item.itemKey) } label: { Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: "checkmark.circle") }
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
    var body: some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(names, id: \.self) { n in
                            VStack(spacing: 4) {
                                ArtworkImage.Placeholder(title: n).frame(width: 56, height: 56).clipShape(Circle())
                                Text(n).font(.caption2).foregroundStyle(.secondary).frame(width: 72).lineLimit(2).multilineTextAlignment(.center)
                            }
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
    @State private var chosenFile: MediaFile?

    var body: some View {
        let ws = library.watchState(film.itemKey)
        let file = chosenFile ?? library.preferredFile(film)
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
                CastRow(names: film.cast).padding(.horizontal)
                if film.files.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Versions").font(.headline); Spacer(); Text("Tap to choose").font(.caption).foregroundStyle(.secondary) }
                        ForEach(film.files, id: \.id) { f in
                            Button { chosenFile = f } label: {
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
                        if !file.sidecars.isEmpty { LabeledContent("Subtitles", value: "\(file.sidecars.count) sidecar file\(file.sidecars.count == 1 ? "" : "s")").font(.footnote) }
                    }.padding(.horizontal)
                }
            }.padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}

// MARK: - Show

struct ShowDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerCoordinator
    let show: MediaItem
    var initialSeason: Int? = nil
    @State private var season: Int?
    @State private var fixMatchTarget: MediaItem?

    private var seasons: [Int] { Array(Set(show.episodes.compactMap(\.seasonNumber))).sorted() }
    private var selected: Int { season ?? initialSeason ?? library.nextEpisode(of: show)?.seasonNumber ?? seasons.first ?? 1 }
    private var episodes: [MediaItem] { show.episodes.filter { $0.seasonNumber == selected }.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) } }

    var body: some View {
        let next = library.nextEpisode(of: show)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeroHeader(item: show, subtitle: [show.year.map(String.init), "\(seasons.count) season\(seasons.count == 1 ? "" : "s")", show.genres.prefix(2).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), fixMatchTarget: $fixMatchTarget)
                if let next {
                    Button { player.play(next, settings: settings) } label: {
                        Label("Play \(next.episodeCode ?? "")", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
                }
                Facts(facts: [
                    show.rating.map { ("★ \(String(format: "%.1f", $0))", nil) },
                    ("\(library.unwatchedCount(show)) unwatched", nil),
                    show.confidence == .autoLow ? ("Low-confidence match", .yellow) : nil,
                ].compactMap { $0 }).padding(.horizontal)
                if let o = show.overview { Text(o).font(.subheadline).padding(.horizontal) }
                CastRow(names: show.cast).padding(.horizontal)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Episodes").font(.headline).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(seasons, id: \.self) { s in FilterBar.Chip(text: "Season \(s)", on: s == selected) { season = s } }
                        }.padding(.horizontal)
                    }
                    ForEach(episodes, id: \.itemKey) { ep in
                        EpisodeRow(episode: ep).padding(.horizontal)
                            .onTapGesture { player.play(ep, settings: settings) }
                            .contextMenu {
                                let watched = library.watchState(ep.itemKey)?.watched == true
                                Button { library.setWatched(!watched, itemKey: ep.itemKey) } label: { Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: "checkmark.circle") }
                                Button { player.play(ep, fromStart: true, settings: settings) } label: { Label("Play from start", systemImage: "gobackward") }
                            }
                    }
                }
            }.padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject private var library: LibraryStore
    let episode: MediaItem
    var body: some View {
        let ws = library.watchState(episode.itemKey)
        HStack(alignment: .top, spacing: 12) {
            ArtworkImage(url: ArtworkURL.still(episode.stillPath), title: episode.title, aspect: 16 / 9, cornerRadius: 8).frame(width: 120)
                .overlay(alignment: .topLeading) { if ws?.watched == true { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.black).padding(4).background(.green, in: Circle()).padding(6) } }
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
