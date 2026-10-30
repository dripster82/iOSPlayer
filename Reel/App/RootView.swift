import SwiftUI
import Sync
import Library

enum AppSection: String, CaseIterable, Identifiable {
    case home, tv, films, downloads, files, favourites, collections, sources, search, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .tv: "TV Shows"; case .films: "Films"; case .downloads: "Downloads"; case .files: "Files"; case .favourites: "Favourites"
        case .collections: "Collections"; case .sources: "Sources"; case .search: "Search"; case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"; case .tv: "tv"; case .films: "film"; case .downloads: "arrow.down.circle"; case .files: "folder"; case .favourites: "heart"
        case .collections: "rectangle.stack"; case .sources: "externaldrive.connected.to.line.below"; case .search: "magnifyingglass"; case .settings: "gearshape"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
        case .home: HomeView()
        case .tv: TVView()
        case .films: FilmsView()
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
                    List(selection: $nav.section) {
                        ForEach([AppSection.home, .tv, .films, .downloads, .files, .favourites, .collections, .sources, .search]) { s in
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
                // Five tabs fit the phone's bar without a "More" tab. Files holds the plain view of
                // every source and, as its first row, Downloads; Sources sits in Settings → Libraries.
                TabView(selection: Binding(get: { nav.section ?? .home }, set: { nav.section = $0 })) {
                    ForEach([AppSection.home, .tv, .films, .files, .search]) { s in
                        NavigationStack(path: nav.binding(for: s)) { s.view }
                            .tabItem { Label(s.title, systemImage: s.icon) }
                            .tag(s)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView()
        }
        .alert("Couldn't play", isPresented: Binding(get: { player.loadError != nil && !player.isPresented }, set: { if !$0 { player.loadError = nil } })) {
            Button("OK") { player.loadError = nil }
        } message: { Text(player.loadError ?? "") }
    }
}
