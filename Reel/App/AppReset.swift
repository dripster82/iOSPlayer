import Foundation
import UIKit
import MediaCore

/// Settings → Reset Reel: puts the app back to a first run. Everything in the app's own container
/// goes (the library store, downloads, caches, diagnostics) along with its defaults (settings, sync
/// state, onboarding); the app then quits, and the next launch is a fresh install. Nothing in
/// iCloud is touched, and source passwords stay in iCloud Keychain, where a real reinstall would
/// leave them too, so Restore from iCloud works straight after.
enum AppReset {
    static func performAndQuit() {
        Diagnostics.log("app", "reset: removing all local data and quitting")
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory, .libraryDirectory] {
            for base in fm.urls(for: dir, in: .userDomainMask) {
                for entry in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                    // Library/ holds Preferences and the system's own folders; those are reset separately or left alone.
                    if dir == .libraryDirectory, !["Application Support", "Caches"].contains(entry.lastPathComponent) { continue }
                    try? fm.removeItem(at: entry)
                }
            }
        }
        // Key by key as well as the whole domain: removing only the domain left the preferences
        // daemon serving the old values to the relaunched app.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        if let id = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: id) }
        defaults.synchronize()
        Diagnostics.log("app", "reset: onboarding flag now \(defaults.object(forKey: "hasCompletedOnboarding") == nil ? "absent" : "still present")")
        // A hard exit is the only way to drop the open store and every in-memory object at once;
        // iOS relaunches the app clean on the next tap. The pause lets the preferences write land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
    }
}
