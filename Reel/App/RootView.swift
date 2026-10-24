import SwiftUI
import Library

enum AppSection: String, CaseIterable, Identifiable {
    case home, tv, films, downloads, favourites, collections, sources, search, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .tv: "TV Shows"; case .films: "Films"; case .downloads: "Downloads"; case .favourites: "Favourites"
        case .collections: "Collections"; case .sources: "Sources"; case .search: "Search"; case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"; case .tv: "tv"; case .films: "film"; case .downloads: "arrow.down.circle"; case .favourites: "heart"
        case .collections: "rectangle.stack"; case .sources: "externaldrive.connected.to.line.below"; case .search: "magnifyingglass"; case .settings: "gearshape"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
        case .home: HomeView()
        case .tv: TVView()
        case .films: FilmsView()
        case .downloads: DownloadsView()
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
    @State private var section: AppSection? = .home

    var body: some View {
        Group {
            if !settings.hasCompletedOnboarding && library.sources().isEmpty {
                OnboardingView()
            } else if sizeClass == .regular {
                NavigationSplitView {
                    List(selection: $section) {
                        ForEach([AppSection.home, .tv, .films, .downloads, .favourites, .collections, .sources, .search]) { s in
                            Label(s.title, systemImage: s.icon).tag(s)
                        }
                        Spacer()
                        Label(AppSection.settings.title, systemImage: AppSection.settings.icon).tag(AppSection.settings)
                    }
                    .navigationTitle("Reel")
                } detail: {
                    NavigationStack { (section ?? .home).view }
                }
            } else {
                // Five tabs fit the phone's bar without a "More" tab. Sources moved to Settings →
                // Libraries (and the Home banners) when Downloads took its place.
                TabView {
                    ForEach([AppSection.home, .tv, .films, .downloads, .search]) { s in
                        NavigationStack { s.view }
                            .tabItem { Label(s.title, systemImage: s.icon) }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView()
        }
        .fullScreenCover(item: $player.nativePlayback) { NativePlayerView(playback: $0) }
        .alert("Couldn't play", isPresented: Binding(get: { player.loadError != nil && !player.isPresented }, set: { if !$0 { player.loadError = nil } })) {
            Button("OK") { player.loadError = nil }
        } message: { Text(player.loadError ?? "") }
    }
}
