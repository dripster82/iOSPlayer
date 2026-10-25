import SwiftUI
import MediaCore
import Library
import Metadata

/// Poster + title + subtitle. Badges: unwatched count, low-confidence "?", watched tick, favourite heart, progress bar.
struct PosterCard: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    var subtitle: String? = nil
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ArtworkImage(url: wide ? (ArtworkURL.still(item.stillPath) ?? item.backdropURL(size: .small) ?? item.posterURL) : item.posterURL, title: item.title, aspect: wide ? 16 / 9 : 2 / 3)
                    .overlay(alignment: .bottom) {
                        if let p = progress {
                            GeometryReader { g in
                                Rectangle().fill(.black.opacity(0.45)).frame(height: 4)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: g.size.width * p, height: 4) }
                            }.frame(height: 4)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if watched { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.black).padding(4).background(.green, in: Circle()).padding(6) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if library.isFavourite(item.itemKey) { Image(systemName: "heart.fill").font(.footnote).foregroundStyle(Color.accentColor).shadow(radius: 3).padding(6) }
                    }
                if let badge {
                    Text(badge.text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(badge.low ? Color.yellow : Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.black).padding(6)
                }
            }
            Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(subtitle ?? defaultSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var defaultSubtitle: String {
        switch item.kind {
        case .show: item.seasonsLabel
        case .film: [item.year.map(String.init), library.preferredFile(item)?.resolution].compactMap { $0 }.joined(separator: " · ")
        case .episode: item.episodeCode ?? ""
        }
    }

    private var progress: Double? {
        guard item.kind != .show, let ws = library.watchState(item.itemKey), ws.isInProgress else { return nil }
        return ws.progress
    }
    private var watched: Bool { item.kind != .show && library.watchState(item.itemKey)?.watched == true }
    private var badge: (text: String, low: Bool)? {
        if item.kind == .show { let n = library.unwatchedCount(item); return n > 0 ? ("\(n)", false) : nil }
        if item.confidence == .autoLow { return ("?", true) }
        if item.kind != .episode, item.addedAt > Date().addingTimeInterval(-7 * 86400), library.watchState(item.itemKey)?.watched != true { return ("New", false) }
        return nil
    }
}

/// Long-press / context menu shared by every poster.
struct ItemContextMenu: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let item: MediaItem
    @Binding var fixMatchTarget: MediaItem?
    @State private var artworkTarget: MediaItem?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { library.toggleFavourite(item.itemKey) } label: {
                Label(library.isFavourite(item.itemKey) ? "Remove from Favourites" : "Add to Favourites", systemImage: library.isFavourite(item.itemKey) ? "heart.slash" : "heart")
            }
            if item.kind != .show {
                let state = library.watchState(item.itemKey)
                let watched = state?.watched == true
                Button { library.setWatched(!watched, itemKey: item.itemKey) } label: { Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: watched ? "eye.slash" : "checkmark.circle") }
                if state?.isInProgress == true {
                    Button { library.clearProgress(itemKey: item.itemKey) } label: { Label("Remove from Continue Watching", systemImage: "xmark.circle") }
                }
            } else {
                Button { item.episodes.forEach { library.setWatched(true, itemKey: $0.itemKey) } } label: { Label("Mark all watched", systemImage: "checkmark.circle") }
            }
            if settings.tmdb != nil {
                Button { fixMatchTarget = item } label: { Label("Fix match", systemImage: "wrench.and.screwdriver") }
            }
            let collections = library.collections()
            if !collections.isEmpty, item.kind != .episode {
                Menu("Add to collection") {
                    ForEach(collections, id: \.id) { c in
                        Button { library.toggle(item.itemKey, in: c) } label: { Label(c.name, systemImage: c.itemKeys.contains(item.itemKey) ? "checkmark" : "rectangle.stack") }
                    }
                }
            }
            if item.kind != .episode, settings.tmdb != nil {
                Button { artworkTarget = item } label: { Label("Edit artwork…", systemImage: "photo.on.rectangle") }
            }
            Divider()
            Button(role: .destructive) { try? library.hide(item) } label: { Label("Hide from library", systemImage: "eye.slash") }
        }
        .sheet(item: $artworkTarget) { ArtworkPickerView(target: .item($0)) }
    }
}

extension View {
    func itemContextMenu(_ item: MediaItem, fixMatchTarget: Binding<MediaItem?>) -> some View {
        modifier(ItemContextMenu(item: item, fixMatchTarget: fixMatchTarget))
    }
}
