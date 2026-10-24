import SwiftUI
import MediaCore
import Library

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerCoordinator
    @State private var fixMatchTarget: MediaItem?
    @State private var showReview = false
    /// Rows are computed off the render path: the store publishes on every scan step, and walking every
    /// show for Next Up on each of those re-renders was dropping taps in the player sitting above Home.
    @State private var rows = Rows()
    @State private var refreshTask: Task<Void, Never>?

    struct Rows {
        var continueWatching: [(MediaItem, WatchState)] = []
        var nextUp: [MediaItem] = []
        var favourites: [MediaItem] = []
        var recentlyAdded: [MediaItem] = []
        var unwatchedFilms: [MediaItem] = []
        var isEmpty = true
        var reviewCount = 0
        var unmatched = 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                offlineBanner
                scanBanner
                unmatchedBanner
                ItemRow(title: "Continue Watching", items: rows.continueWatching.map(\.0), wide: true, subtitle: { item in
                    guard let ws = rows.continueWatching.first(where: { $0.0.itemKey == item.itemKey })?.1 else { return "" }
                    let prefix = item.kind == .episode ? (item.episodeCode ?? "") + " · " : ""
                    return prefix + MediaFormat.minutesLeft(ws.duration - ws.position)
                }, onTap: { player.play($0, settings: settings) }, fixMatchTarget: $fixMatchTarget)
                ItemRow(title: "Next Up", items: rows.nextUp, wide: true, subtitle: { "\($0.show?.title ?? "") · \($0.episodeCode ?? "")" }, onTap: { player.play($0, settings: settings) }, fixMatchTarget: $fixMatchTarget)
                ItemRow(title: "Favourites", items: rows.favourites, fixMatchTarget: $fixMatchTarget)
                ItemRow(title: "Recently Added", items: rows.recentlyAdded, subtitle: { _ in "Added recently" }, fixMatchTarget: $fixMatchTarget)
                ItemRow(title: "Unwatched Films", items: rows.unwatchedFilms, fixMatchTarget: $fixMatchTarget)
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("Your library is empty", systemImage: "film.stack")
                    } description: {
                        Text(settings.tmdb == nil ? "Add a TMDb API key in Settings, then add a source and scan."
                             : rows.unmatched > 0 ? "Your files are scanned but not matched yet. Tap Match now above."
                             : "Add a source and run a scan to fill it.")
                    } actions: {
                        NavigationLink("Open Sources") { SourcesView() }
                    }.padding(.top, 60)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                let n = rows.reviewCount
                NavigationLink { NeedsReviewView() } label: {
                    Image(systemName: "wrench.and.screwdriver").overlay(alignment: .topTrailing) {
                        if n > 0 { Text("\(n)").font(.caption2.bold()).padding(3).background(.red, in: Circle()).foregroundStyle(.white).offset(x: 8, y: -8) }
                    }
                }
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .itemNavigation()
        .sheet(item: $fixMatchTarget) { FixMatchView(item: $0) }
        .onAppear { refreshRows() }
        .onReceive(library.objectWillChange) { _ in scheduleRefresh() }
    }

    /// Coalesces bursts of store changes (a running scan) into one recompute, after the change has landed.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            refreshRows()
        }
    }

    private func refreshRows() {
        var r = Rows()
        r.continueWatching = library.continueWatching()
        r.nextUp = library.nextUp()
        r.favourites = Array(library.favourites().prefix(12))
        let films = library.items(kind: .film), shows = library.items(kind: .show)
        r.recentlyAdded = (films + shows).sorted { $0.addedAt > $1.addedAt }.prefix(12).map { $0 }
        r.unwatchedFilms = films.filter { library.watchState($0.itemKey)?.watched != true }.prefix(12).map { $0 }
        r.isEmpty = films.isEmpty && shows.isEmpty
        r.reviewCount = library.filesNeedingReview().count
        r.unmatched = library.unmatchedFileCount()
        rows = r
    }

    @ViewBuilder private var offlineBanner: some View {
        if let s = library.sources().first(where: { $0.status == .offline || $0.status == .authFailed }) {
            Banner(colour: .red, text: s.status == .authFailed ? "Password rejected for \(s.name)." : "\(s.name) is offline. Showing cached library.") {
                NavigationLink("Details") { SourceDetailView(source: s) }
            }
        }
    }
    @ViewBuilder private var scanBanner: some View {
        if let p = library.scanProgress.values.first(where: { $0.phase != .done && $0.phase != .failed }) {
            Banner(colour: .yellow, text: "Scanning \(p.sourceName): \(p.filesSeen) files, \(p.matched) matched") { ProgressView() }
        }
    }
    /// Files were scanned but never matched (no TMDb key at the time, or the matcher hit errors).
    @ViewBuilder private var unmatchedBanner: some View {
        let scanning = library.scanProgress.values.contains { $0.phase != .done && $0.phase != .failed }
        let unmatched = rows.unmatched
        if !scanning, unmatched > 0 {
            if let err = library.lastMatchError {
                Banner(colour: .red, text: "\(unmatched) files not matched. Last error: \(err)") {
                    Button("Retry") { library.scanAll(providers: settings.providers) }.disabled(settings.tmdb == nil)
                }
            } else {
                Banner(colour: .yellow, text: settings.tmdb == nil ? "\(unmatched) files scanned. Add a TMDb key in Settings to match them." : "\(unmatched) files scanned but not matched yet.") {
                    if settings.tmdb != nil { Button("Match now") { library.scanAll(providers: settings.providers) } }
                    else { NavigationLink("Settings") { SettingsView() } }
                }
            }
        }
    }
}

struct Banner<Trailing: View>: View {
    let colour: Color
    let text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(text).font(.footnote)
            Spacer()
            trailing.font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 3).padding(.vertical, 8) }
        .padding(.horizontal)
    }
}
