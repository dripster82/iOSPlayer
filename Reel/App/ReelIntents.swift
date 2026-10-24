import AppIntents
import Foundation

/// "Continue watching in Reel": opens the app on the most recent unfinished title.
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue watching"
    static let description = IntentDescription("Plays the title you were last watching.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        ReelRoutes.pending = .continueWatching
        return .result()
    }
}

/// "Play the next episode of <show> in Reel".
struct PlayNextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play next episode"
    static let description = IntentDescription("Plays the next unwatched episode of a show in your library.")
    static let openAppWhenRun = true
    @Parameter(title: "Show") var show: ShowEntity
    static var parameterSummary: some ParameterSummary { Summary("Play the next episode of \(\.$show)") }
    @MainActor func perform() async throws -> some IntentResult {
        ReelRoutes.pending = .nextEpisode(showKey: show.id)
        return .result()
    }
}

struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show")
    static let defaultQuery = ShowQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ShowQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShowEntity] {
        ReelRoutes.shows().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [ShowEntity] {
        ReelRoutes.shows().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [ShowEntity] { Array(ReelRoutes.shows().prefix(20)) }
}

struct ReelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueWatchingIntent(), phrases: ["Continue watching in \(.applicationName)", "Resume in \(.applicationName)"],
                    shortTitle: "Continue watching", systemImageName: "play.circle")
        AppShortcut(intent: PlayNextEpisodeIntent(), phrases: ["Play the next episode of \(\.$show) in \(.applicationName)", "Next episode of \(\.$show) in \(.applicationName)"],
                    shortTitle: "Next episode", systemImageName: "forward.end")
    }
}

/// Hand-off between an intent (which runs before the app's scene is ready) and the app, plus the
/// show list the Siri picker reads. The app writes `showsSnapshot` whenever the library changes.
enum ReelRoutes {
    enum Route { case continueWatching, nextEpisode(showKey: String) }
    @MainActor static var pending: Route? { didSet { onPending?() } }
    @MainActor static var onPending: (() -> Void)?

    static func shows() -> [ShowEntity] {
        guard let data = UserDefaults.standard.data(forKey: "reel.showsSnapshot"), let list = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return list.compactMap { $0.count == 2 ? ShowEntity(id: $0[0], name: $0[1]) : nil }
    }
    static func writeShowsSnapshot(_ shows: [(key: String, name: String)]) {
        if let data = try? JSONEncoder().encode(shows.map { [$0.key, $0.name] }) { UserDefaults.standard.set(data, forKey: "reel.showsSnapshot") }
    }
}
