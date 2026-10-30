import SwiftUI
import Sync
import Library

enum AppSection: String, CaseIterable, Identifiable {
    case home, tv, films, audiobooks, downloads, files, favourites, collections, sources, search, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .tv: "TV Shows"; case .films: "Films"; case .audiobooks: "Audiobooks"; case .downloads: "Downloads"; case .files: "Files"; case .favourites: "Favourites"
        case .collections: "Collections"; case .sources: "Sources"; case .search: "Search"; case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"; case .tv: "tv"; case .films: "film"; case .audiobooks: "headphones"; case .downloads: "arrow.down.circle"; case .files: "folder"; case .favourites: "heart"
        case .collections: "rectangle.stack"; case .sources: "externaldrive.connected.to.line.below"; case .search: "magnifyingglass"; case .settings: "gearshape"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
        case .home: HomeView()
        case .tv: TVView()
        case .films: FilmsView()
        case .audiobooks: AudiobooksView()
        case .downloads: DownloadsView()
        case .files: FilesView()
        case .favourites: FavouritesView()
        case .collections: CollectionsView()
        case .sources: SourcesView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

/// iPhone: tab bar. iPad: sidebar + split view. The player is a full-screen cover over both.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var nav: AppNavigation
    @EnvironmentObject private var sync: SyncEngine

    var body: some View {
        Group {
            if !settings.hasCompletedOnboarding && library.sources().isEmpty {
                OnboardingView()
            } else if let progress = sync.restore, !sync.restoreHidden {
                RestoreView(progress: progress)
            } else if sizeClass == .regular {
                NavigationSplitView {
                    // Audiobooks shows only once a scan has found a book.
                    let hasBooks = !library.audiobooks().isEmpty
                    List(selection: $nav.section) {
                        ForEach([AppSection.home, .tv, .films] + (hasBooks ? [.audiobooks] : []) + [.downloads, .files, .favourites, .collections, .sources, .search]) { s in
                            Label(s.title, systemImage: s.icon).tag(s)
                        }
                        Spacer()
                        Label(AppSection.settings.title, systemImage: AppSection.settings.icon).tag(AppSection.settings)
                    }
                    .navigationTitle("Reel")
                } detail: {
                    NavigationStack(path: nav.binding(for: nav.section ?? .home)) { (nav.section ?? .home).view }
                }
            } else {
                // Five tabs fit the phone's bar without a "More" tab: Home, TV, Films, Audiobooks once
                // a book exists, and Files (Downloads is its first row). Search is the magnifier in
                // every tab's top bar; Sources sits in Settings → Libraries.
                let hasBooks = !library.audiobooks().isEmpty
                TabView(selection: Binding(get: { nav.section ?? .home }, set: { nav.section = $0 })) {
                    ForEach([AppSection.home, .tv, .films] + (hasBooks ? [.audiobooks] : []) + [.files]) { s in
                        NavigationStack(path: nav.binding(for: s)) { s.view }
                            .tabItem { Label(s.title, systemImage: s.icon) }
                            .tag(s)
                    }
                }
            }
        }
        .onAppear { nav.searchIsAPage = sizeClass == .compact }
        .onChange(of: sizeClass) { _, c in nav.searchIsAPage = c == .compact }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView()
        }
        .alert("Couldn't play", isPresented: Binding(get: { player.loadError != nil && !player.isPresented }, set: { if !$0 { player.loadError = nil } })) {
            Button("OK") { player.loadError = nil }
        } message: { Text(player.loadError ?? "") }
    }
}
