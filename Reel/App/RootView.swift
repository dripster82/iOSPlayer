import SwiftUI
import Sync
import Library
import MediaCore

enum AppSection: String, CaseIterable, Identifiable {
    case home, tv, films, audiobooks, downloads, files, favourites, history, collections, sources, search, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .tv: "TV Shows"; case .films: "Films"; case .audiobooks: "Audiobooks"; case .downloads: "Downloads"; case .files: "Files"; case .favourites: "Favourites"; case .history: "History"
        case .collections: "Collections"; case .sources: "Sources"; case .search: "Search"; case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"; case .tv: "tv"; case .films: "film"; case .audiobooks: "headphones"; case .downloads: "arrow.down.circle"; case .files: "folder"; case .favourites: "heart"; case .history: "clock"
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
        case .history: HistoryView()
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

    /// One launch with a cut-down tree, to bisect the post-reboot freeze (set by
    /// `reel://debug-plain-root?level=N`, cleared on use). 1: a plain label (cleared the shell and
    /// iPadOS on 16 Nov: no freeze). 2: the split view with the sidebar and an empty detail.
    /// 3: a navigation stack holding Home, no split view. 4: the split view with a plain detail stack.
    @State private var testLevel = UserDefaults.standard.integer(forKey: RootView.plainRootKey)
    static let plainRootKey = "reel.debugPlainRootLevel"

    @ViewBuilder private var sidebar: some View {
        List(selection: $nav.section) {
            ForEach([AppSection.home, .tv, .films, .downloads, .files, .favourites, .history, .collections, .sources, .search]) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
        }
        .navigationTitle("Reel")
    }

    var body: some View {
        let _ = Diagnostics.count("Root body")
        Group {
            if testLevel > 0 {
                Group {
                    switch testLevel {
                    case 2: NavigationSplitView { sidebar } detail: { Text("Detail") }
                    case 3: NavigationStack { HomeView() }
                    case 4: NavigationSplitView { sidebar } detail: { NavigationStack { Text("Detail") } }
                    default: Text("Plain root test").font(.largeTitle)
                    }
                }
                .task { UserDefaults.standard.removeObject(forKey: RootView.plainRootKey); Diagnostics.log("app", "root test level \(testLevel) launch (flag cleared)") }
            } else if !settings.hasCompletedOnboarding && library.sources().isEmpty {
                OnboardingView()
            } else if let progress = sync.restore, !sync.restoreHidden {
                RestoreView(progress: progress)
            } else if sizeClass == .regular {
                NavigationSplitView {
                    // Audiobooks shows only once a scan has found a book.
                    let hasBooks = !library.audiobooks().isEmpty
                    List(selection: $nav.section) {
                        ForEach([AppSection.home, .tv, .films] + (hasBooks ? [.audiobooks] : []) + [.downloads, .files, .favourites, .history, .collections, .sources, .search]) { s in
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
                // The last book removed while its tab is up: the tab goes, so the selection must too.
                .onChange(of: hasBooks) { _, has in if !has, nav.section == .audiobooks { nav.section = .home } }
            }
        }
        .onAppear { LaunchTrace.firstFrame(state: UIApplication.shared.applicationState); nav.searchIsAPage = sizeClass == .compact }
        // The root's size at the first frame and on every change: a lazy shelf laid out at an unbounded
        // or placeholder width would build every card, and the post-reboot stall looks like that.
        .background(GeometryReader { g in
            Color.clear.onChange(of: g.size, initial: true) { _, size in
                Diagnostics.log("app", "root size \(Int(size.width))×\(Int(size.height)), size class \(sizeClass == .compact ? "compact" : sizeClass == .regular ? "regular" : "none")")
            }
        })
        .onChange(of: sizeClass) { _, c in nav.searchIsAPage = c == .compact }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView()
        }
        .alert("Couldn't play", isPresented: Binding(get: { player.loadError != nil && !player.isPresented }, set: { if !$0 { player.loadError = nil } })) {
            Button("OK") { player.loadError = nil }
        } message: { Text(player.loadError ?? "") }
    }
}

