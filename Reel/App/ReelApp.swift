import SwiftUI
import MediaCore
import UIKit
import SwiftData
import Library
import Sync
import Metadata

@main
struct ReelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var library: LibraryStore
    @StateObject private var sync: SyncEngine
    @StateObject private var player: PlayerCoordinator
    @StateObject private var downloads: DownloadManager
    @StateObject private var groupArt: GroupArtStore
    @StateObject private var smart = SmartCollectionStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do { container = try LibrarySchema.container() }
        catch {
            // A broken store on launch is worse than an empty one; start fresh and say so in Settings.
            container = try! LibrarySchema.container(inMemory: true)
        }
        let store = LibraryStore(container: container)
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: store)
        let sync = SyncEngine(container: container, cloudContainerID: AppSettings.cloudContainerID)
        _sync = StateObject(wrappedValue: sync)
        _player = StateObject(wrappedValue: PlayerCoordinator(library: store))
        _downloads = StateObject(wrappedValue: DownloadManager(library: store))
        _groupArt = StateObject(wrappedValue: GroupArtStore(library: store))
        // Every local write pushes straight away, so putting one device down and picking up another just works.
        store.syncHooks = SyncHooks(changed: { [weak sync] in sync?.pushPendingChanges() },
                                    deleted: { [weak sync] keys in sync?.deleteRecords(named: keys) })
        sync.onChangesApplied = { [weak store] in store?.invalidateCaches(); store?.objectWillChange.send() }
        // Must happen before launch finishes, so here rather than in a view.
        BackgroundScans.register(library: store, settings: settings)
    }

    /// "Open in Reel" from another app (a file URL), or `reel://play?url=…` / `reel://x-callback-url/play?url=…`.
    /// Plays what a Siri intent asked for, once the scene is up.
    private func runPendingRoute() {
        guard let route = ReelRoutes.pending else { return }
        ReelRoutes.pending = nil
        switch route {
        case .continueWatching:
            if let (item, _) = library.continueWatching().first { player.play(item, settings: settings) }
        case .nextEpisode(let showKey):
            if let show = library.item(showKey), let next = library.nextEpisode(of: show) { player.play(next, settings: settings) }
        }
    }

    private func open(_ url: URL) {
        if url.isFileURL { player.playExternal(url, settings: settings); return }
        guard url.scheme?.lowercased() == "reel" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = (url.host == "x-callback-url" ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.host) ?? ""
        guard action == "play", let raw = comps?.queryItems?.first(where: { $0.name == "url" })?.value, let target = URL(string: raw) else { return }
        let title = comps?.queryItems?.first(where: { $0.name == "title" })?.value
        player.playExternal(target, title: title, settings: settings)
    }

    /// Incremental scan of every source when the app comes to the foreground: listing is cheap and only
    /// new or changed files go to TMDb. Throttled so switching apps doesn't restart it every time.
    /// Persisted, so killing and relaunching the app inside ten minutes does not scan again: each scan
    /// publishes progress every second, which has every screen rebuilding its rows for its duration.
    private var lastForegroundScan: Date {
        get { UserDefaults.standard.object(forKey: "reel.lastForegroundScan") as? Date ?? .distantPast }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "reel.lastForegroundScan") }
    }

    private func scanForNewMediaIfDue() {
        guard settings.scanOnLaunch, settings.hasCompletedOnboarding, !library.isScanning,
              Date().timeIntervalSince(lastForegroundScan) > 10 * 60, !library.sources().isEmpty else { return }
        lastForegroundScan = Date()
        library.scanAll(providers: settings.providers)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(sync)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(groupArt)
                .environmentObject(smart)
                .modelContainer(library.container)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { library.purgePendingDeletions(); await ImageLoader.shared.enforceLimit() }
                .task {
                    // Siri: act on a route an intent left, and keep the show list Siri's picker reads current.
                    ReelRoutes.onPending = { runPendingRoute() }
                    runPendingRoute()
                    ReelRoutes.writeShowsSnapshot(library.items(kind: .show).map { ($0.itemKey, $0.title) })
                }
                .onReceive(library.objectWillChange.debounce(for: .seconds(5), scheduler: DispatchQueue.main)) { _ in
                    ReelRoutes.writeShowsSnapshot(library.items(kind: .show).map { ($0.itemKey, $0.title) })
                }
                .task(priority: .background) { if let tmdb = settings.tmdb { await library.backfillCollections(tmdb: tmdb) } }
                .onOpenURL { url in open(url) }
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.remoteNotification)) { _ in
                    Task { await sync.fetchNow() }
                }
                .onChange(of: scenePhase) { _, phase in
                    Diagnostics.log("app", "scene \(phase)")
                    // Leaving the foreground (switching apps, locking, PiP hand-off): save the position
                    // now and get it to iCloud before iOS suspends us, so the other device can pick up
                    // exactly where this one stopped.
                    if phase == .inactive || phase == .background {
                        player.flushProgress()
                        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Reel progress sync")
                        Task { await sync.sendNow(); UIApplication.shared.endBackgroundTask(assertion) }
                    }
                    if phase == .active {
                        Task { await sync.fetchNow(); sync.pushPendingChanges() }
                        scanForNewMediaIfDue()
                    }
                    guard phase == .background else { return }
                    // Finish an interrupted scan or match soon; otherwise refresh daily (PLAN §11.3).
                    let pending = library.isScanning || library.unmatchedFileCount() > 0
                    BackgroundScans.schedule(after: pending ? 60 : 24 * 3600)
                }
        }
    }
}
