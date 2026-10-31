import SwiftUI
import MediaCore
import Playback
import Library
import MediaSources

/// Where the app is: the selected section and each section's pushed pages. Deep links
/// (reel://open/tv, reel://item?title=Firefly) and Siri hand-offs drive it; RootView binds to it.
@MainActor
final class AppNavigation: ObservableObject {
    @Published var section: AppSection? = .home
    @Published var paths: [AppSection: NavigationPath] = [:]

    func binding(for s: AppSection) -> Binding<NavigationPath> {
        Binding(get: { self.paths[s] ?? NavigationPath() }, set: { self.paths[s] = $0 })
    }

    /// True on the phone, where Search is a page pushed in the current tab rather than a tab.
    var searchIsAPage = false

    func show(_ s: AppSection) {
        if s == .search, searchIsAPage {
            let home = AppSection.home
            section = home
            var p = NavigationPath(); p.append(LibraryRoute.search)
            paths[home] = p
            return
        }
        section = s
        paths[s] = NavigationPath()
    }

    /// Opens a title's page in the current section.
    func open(itemKey: String) {
        let s = section ?? .home
        var p = NavigationPath(); p.append(itemKey)
        paths[s] = p
    }

    func open(route: LibraryRoute) {
        let s = section ?? .home
        var p = NavigationPath(); p.append(route)
        paths[s] = p
    }
}

/// `reel://` links beyond `play?url=`. Used by Siri shortcuts and by automation (screenshots).
///
///   reel://open/home|tv|films|downloads|search|collections|settings|favourites
///   reel://item?key=<itemKey>  or  reel://item?title=<text>   (first search hit)
///   reel://play?key=<itemKey>  or  reel://play?title=<text>
///   reel://stop   (closes the player)
///   reel://scan
///   reel://demo
///   reel://addsource?type=webdav&host=…&port=…&path=…&name=…&tls=0&tags=Films:films,TV:tv   (Debug builds only)
enum DeepLinks {
    @MainActor
    static func handle(_ url: URL, nav: AppNavigation, library: LibraryStore, player: PlayerCoordinator, settings: AppSettings) -> Bool {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let q = Dictionary((comps?.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let action = url.host ?? ""
        let arg = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func find() -> MediaItem? {
            if let key = q["key"], let item = library.item(key) { return item }
            if let title = q["title"] {
                let hits = library.search(title)
                return hits.first { $0.title.caseInsensitiveCompare(title) == .orderedSame } ?? hits.first
            }
            return nil
        }
        switch action {
        case "open":
            switch arg {
            case "collections": nav.show(.home); Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); nav.open(route: .collections) }
            case "favourites": nav.show(.home); Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); nav.open(route: .favourites) }
            // History is a sidebar section on the iPad and a page over Home on the phone.
            case "history" where nav.searchIsAPage: nav.show(.home); Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); nav.open(route: .history) }
            case "settings": nav.show(.settings)
            default: if let s = AppSection(rawValue: arg) { nav.show(s) } else { return false }
            }
            return true
        case "item":
            guard let item = find() else { return false }
            let key = item.kind == .episode ? (item.show?.itemKey ?? item.itemKey) : item.itemKey
            if let s = AppSection(rawValue: q["section"] ?? "") { nav.show(s) }
            // The section's stack must be on screen before a page can be pushed into it.
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); nav.open(itemKey: key) }
            return true
        case "play":
            if q["url"] != nil { return false }   // the stream form is handled by ReelApp.open
            guard let item = find() else { return false }
            let target = item.kind == .show ? library.nextEpisode(of: item) ?? item.episodes.first : item
            if let target { player.play(target, settings: settings) }
            return true
        case "airplaytest":
            #if DEBUG
            // Plays through the AirPlay path (remux + bridge + Apple's player) with no receiver connected.
            guard let item = find() else { return false }
            PlayerCoordinator.debugForceAirPlay = true
            HLSRemuxer.debugSkipProbe = q["noprobe"] == "1"
            HLSRemuxer.debugMediaOptions = (q["opts"] ?? "").split(separator: ",").map { ":" + $0 }
            let target = item.kind == .show ? library.nextEpisode(of: item) ?? item.episodes.first : item
            // `start=<seconds>` tests a copy that begins part-way through, the way a resume does.
            if let target, let start = q["start"].flatMap(Double.init), start > 0 {
                library.recordProgress(itemKey: target.itemKey, position: start, duration: start * 4)
            }
            if let target { player.play(target, fromStart: q["fromStart"] == "1", settings: settings) }
            return true
            #else
            return false
            #endif
        case "stop":
            player.dismiss()
            return true
        case "scan":
            library.scanAll(providers: settings.providers)
            return true
        case "demo":
            DemoLibrary.install(in: library); settings.demoInstalled = true
            return true
        case "removesource":
            #if DEBUG
            // reel://removesource?name=… (Debug builds only): drops a source and its items, for test clean-up.
            if let name = q["name"], let record = library.sources().first(where: { $0.name == name }) {
                try? library.removeSource(record)
                Diagnostics.log("app", "debug link removed source \(name)")
            }
            return true
            #else
            return false
            #endif
        case "addsource":
            #if DEBUG
            guard let type = SourceType(rawValue: q["type"] ?? ""), let host = q["host"] else { return false }
            if q["via"] == "vlc" { SourceFactory.preferVLCForFTP = true }
            let config = SourceConfig(name: q["name"] ?? host, type: type, host: host, port: q["port"].flatMap(Int.init), path: q["path"] ?? "", useTLS: q["tls"] != "0")
            let creds = q["user"].map { Credentials(username: $0, password: q["pass"] ?? "") }
            // tags=Films:films,TV:tv,Books:audiobooks tags folders as the Sources screen would.
            let rules: [(String, FolderTag)] = (q["tags"] ?? "").split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let tag = FolderTag(rawValue: parts[1]) else { return nil }
                return (parts[0], tag)
            }
            do {
                let record = try library.addSource(config, credentials: creds, folderRules: rules)
                library.scan(record, providers: settings.providers)
                Diagnostics.log("app", "debug link added source \(config.name)")
            } catch {
                Diagnostics.log("app", "debug link could not add source: \(error)")
            }
            return true
            #else
            return false
            #endif
        default:
            return false
        }
    }
}
