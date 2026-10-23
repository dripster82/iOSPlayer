import SwiftUI
import SwiftData
import Library
import Sync
import Metadata

@main
struct ReelApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var library: LibraryStore
    @StateObject private var sync: SyncEngine
    @StateObject private var player: PlayerCoordinator

    init() {
        let container: ModelContainer
        do { container = try LibrarySchema.container() }
        catch {
            // A broken store on launch is worse than an empty one; start fresh and say so in Settings.
            container = try! LibrarySchema.container(inMemory: true)
        }
        let store = LibraryStore(container: container)
        _library = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncEngine(container: container, cloudContainerID: AppSettings.cloudContainerID))
        _player = StateObject(wrappedValue: PlayerCoordinator(library: store))
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
        }
    }
}
