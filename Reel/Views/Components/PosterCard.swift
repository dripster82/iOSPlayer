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
        let _ = Diagnostics.count("poster card body")
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
            Text(item.kind == .episode ? (item.show?.title ?? item.title) : item.title).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(subtitle ?? defaultSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var defaultSubtitle: String {
        switch item.kind {
        case .show: item.seasonsLabel
        case .film: [item.year.map(String.init), library.preferredFile(item)?.resolution].compactMap { $0 }.joined(separator: " · ")
        case .episode: item.show?.kind == .audiobook ? "Part \(item.episodeNumber ?? 0)" : [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ")
        case .audiobook: item.author ?? ""
        }
    }

    private var progress: Double? {
        guard item.kind != .show, let ws = library.watchState(item.itemKey), ws.isInProgress else { return nil }
        return ws.progress
    }
    private var watched: Bool { item.kind != .show && library.watchState(item.itemKey)?.watched == true }
    private var badge: (text: String, low: Bool)? {
        if item.kind == .show { let n = library.unwatchedCount(item); return n > 0 ? ("\(n)", false) : nil }
        if item.confidence == .autoLow || item.confidence == .unmatched { return ("?", true) }
        if item.kind != .episode, item.addedAt > Date().addingTimeInterval(-7 * 86400), library.watchState(item.itemKey)?.watched != true { return ("New", false) }
        return nil
    }
}

/// The actions a long press on a poster offers, as a dialog anchored to the card. Nothing is made
/// until the press: a `.contextMenu` on every card is a UIKit interaction on a nested hosting view
/// each, and creating them held the main thread for 10–30 s after a reboot (HANDOVER, 17 Nov 2026).
struct ItemActionsDialog: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let item: MediaItem
    /// The shelf's or grid's pressed item; this card's dialog shows while it is this item.
    @Binding var selection: MediaItem?
    @Binding var fixMatchTarget: MediaItem?
    @Binding var artworkTarget: MediaItem?
    /// In the Continue Watching row the destructive action is leaving that row, not hiding the
    /// title from the library: a long press there is about the list, not the film or show.
    var inContinueWatching = false

    func body(content: Content) -> some View {
        content.confirmationDialog(item.title, isPresented: Binding(get: { selection?.itemKey == item.itemKey }, set: { if !$0, selection?.itemKey == item.itemKey { selection = nil } }), titleVisibility: .visible) {
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        Button { library.toggleFavourite(item.itemKey) } label: {
            Label(library.isFavourite(item.itemKey) ? "Remove from Favourites" : "Add to Favourites", systemImage: library.isFavourite(item.itemKey) ? "heart.slash" : "heart")
        }
        if item.kind != .show {
            let state = library.watchState(item.itemKey)
            let watched = state?.watched == true
            Button { library.setWatched(!watched, itemKey: item.itemKey) } label: { Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: watched ? "eye.slash" : "checkmark.circle") }
            if state?.isInProgress == true, !inContinueWatching {
                Button { library.clearProgress(itemKey: item.itemKey) } label: { Label("Remove from Continue Watching", systemImage: "xmark.circle") }
            }
        } else {
            Button { item.episodes.forEach { library.setWatched(true, itemKey: $0.itemKey) } } label: { Label("Mark all watched", systemImage: "checkmark.circle") }
        }
        if settings.tmdb != nil {
            Button { fixMatchTarget = item } label: { Label("Fix match", systemImage: "wrench.and.screwdriver") }
        }
        // A dialog has no submenus: one line per collection.
        if item.kind != .episode {
            ForEach(library.collections(), id: \.id) { c in
                let member = c.itemKeys.contains(item.itemKey)
                Button { library.toggle(item.itemKey, in: c) } label: { Label(member ? "Remove from “\(c.name)”" : "Add to “\(c.name)”", systemImage: member ? "checkmark" : "rectangle.stack") }
            }
        }
        if item.kind != .episode, settings.tmdb != nil {
            Button { artworkTarget = item } label: { Label("Edit artwork…", systemImage: "photo.on.rectangle") }
        }
        if inContinueWatching {
            Button(role: .destructive) { library.clearProgress(itemKey: item.itemKey) } label: { Label("Remove from Continue Watching", systemImage: "xmark.circle") }
        } else {
            Button(role: .destructive) { try? library.hide(item) } label: { Label("Hide from library", systemImage: "eye.slash") }
        }
    }
}

extension View {
    /// This card's dialog of item actions, shown while `selection` is its item (set by `itemLongPress`).
    func itemActionsDialog(_ item: MediaItem, selection: Binding<MediaItem?>, fixMatchTarget: Binding<MediaItem?>, artworkTarget: Binding<MediaItem?>, inContinueWatching: Bool = false) -> some View {
        modifier(ItemActionsDialog(item: item, selection: selection, fixMatchTarget: fixMatchTarget, artworkTarget: artworkTarget, inContinueWatching: inContinueWatching))
    }
    /// A long press on a card selects its item for the shelf's or grid's dialogs.
    func itemLongPress(_ item: MediaItem, opens target: Binding<MediaItem?>) -> some View {
        // High priority: once the press is long the card's link or button must not fire on release.
        highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in target.wrappedValue = item })
    }
}
