import SwiftUI
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastForegroundScan: Date = .distantPast

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
        // Every local write pushes straight away, so putting one device down and picking up another just works.
        store.syncHooks = SyncHooks(changed: { [weak sync] in sync?.pushPendingChanges() },
                                    deleted: { [weak sync] keys in sync?.deleteRecords(named: keys) })
        // Must happen before launch finishes, so here rather than in a view.
        BackgroundScans.register(library: store, settings: settings)
    }

    /// Incremental scan of every source when the app comes to the foreground: listing is cheap and only
    /// new or changed files go to TMDb. Throttled so switching apps doesn't restart it every time.
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
                .modelContainer(library.container)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { await ImageLoader.shared.enforceLimit() }
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.remoteNotification)) { _ in
                    Task { await sync.fetchNow() }
                }
                .onChange(of: scenePhase) { _, phase in
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
