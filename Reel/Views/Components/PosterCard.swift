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

/// The actions a long press on a poster offers: one dialog per shelf or grid, anchored to the
/// pressed card. Per card there is only a `LongPressGesture`: a `.contextMenu` or a
/// `.confirmationDialog` on every card is a UIKit object per card at launch, and creating them held
/// the main thread for 10–30 s after a reboot (HANDOVER, 17 Nov 2026). A press-then-drag sequence on
/// the shelf was tried instead and held the scroll view's pan for every drag that began on a card.
struct ItemActionsDialog: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// The pressed card's item; nil closes the dialog.
    @Binding var item: MediaItem?
    @Binding var fixMatchTarget: MediaItem?
    /// In the Continue Watching row the destructive action is leaving that row, not hiding the
    /// title from the library: a long press there is about the list, not the film or show.
    var inContinueWatching = false
    @State private var artworkTarget: MediaItem?

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ItemAnchorKey.self) { anchors in
                // An invisible stand-in over the pressed card is the dialog's source.
                GeometryReader { proxy in
                    let r = item.flatMap { anchors[$0.itemKey] }.map { proxy[$0] } ?? .zero
                    Color.clear
                        .frame(width: max(r.width, 1), height: max(r.height, 1))
                        .offset(x: r.minX, y: r.minY)
                        .confirmationDialog(item?.title ?? "", isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }), titleVisibility: .visible, presenting: item) { item in
                            actions(for: item)
                        }
                }
                .allowsHitTesting(false)
            }
            .sheet(item: $artworkTarget) { ArtworkPickerView(target: .item($0)) }
    }

    @ViewBuilder private func actions(for item: MediaItem) -> some View {
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

/// Each card's bounds, by item key, for the shelf's dialog to find the pressed card and anchor to it.
struct ItemAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}

extension View {
    /// The shelf's or grid's one dialog of item actions, opened by `itemLongPress` on a card.
    func itemActionsDialog(for item: Binding<MediaItem?>, fixMatchTarget: Binding<MediaItem?>, inContinueWatching: Bool = false) -> some View {
        modifier(ItemActionsDialog(item: item, fixMatchTarget: fixMatchTarget, inContinueWatching: inContinueWatching))
    }
    /// A long press on a card opens its shelf's or grid's `itemActionsDialog` for `item`, anchored
    /// to this card. High priority, so the card's link does not fire on release; a moving finger
    /// fails the press within ten points and scrolls.
    func itemLongPress(_ item: MediaItem, opens target: Binding<MediaItem?>) -> some View {
        highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in target.wrappedValue = item })
            .anchorPreference(key: ItemAnchorKey.self, value: .bounds) { [item.itemKey: $0] }
    }
}
