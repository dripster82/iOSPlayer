import SwiftUI
import Metadata
import Library

/// User preferences. Everything here is per-device; nothing syncs.
/// `@Published` + `didSet` rather than `@AppStorage`, because `@AppStorage` doesn't notify an ObservableObject's subscribers.
@MainActor
final class AppSettings: ObservableObject {
    static let cloudContainerID = "iCloud.uk.co.ketelle.reel"

    enum Theme: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
        var colorScheme: ColorScheme? { switch self { case .system: nil; case .dark: .dark; case .light: .light } }
        var title: String { rawValue.capitalized }
    }

    private let d = UserDefaults.standard

    @Published var tmdbAPIKey: String { didSet { d.set(tmdbAPIKey, forKey: "tmdbAPIKey") } }
    @Published var tvdbAPIKey: String { didSet { d.set(tvdbAPIKey, forKey: "tvdbAPIKey") } }
    @Published var tvdbPIN: String { didSet { d.set(tvdbPIN, forKey: "tvdbPIN") } }
    @Published var animeMatching: Bool { didSet { d.set(animeMatching, forKey: "animeMatching") } }
    @Published var metadataLanguage: String { didSet { d.set(metadataLanguage, forKey: "metadataLanguage") } }
    @Published var hardwareDecoding: Bool { didSet { d.set(hardwareDecoding, forKey: "hardwareDecoding") } }
    @Published var networkCachingMS: Int { didSet { d.set(networkCachingMS, forKey: "networkCachingMS") } }
    @Published var skipInterval: Int { didSet { d.set(skipInterval, forKey: "skipInterval") } }
    @Published var audioLanguage: String { didSet { d.set(audioLanguage, forKey: "audioLanguage") } }
    @Published var subtitleLanguage: String { didSet { d.set(subtitleLanguage, forKey: "subtitleLanguage") } }
    @Published var subtitlesOnByDefault: Bool { didSet { d.set(subtitlesOnByDefault, forKey: "subtitlesOnByDefault") } }
    @Published var backgroundAudio: Bool { didSet { d.set(backgroundAudio, forKey: "backgroundAudio") } }
    @Published var scanOnCellular: Bool { didSet { d.set(scanOnCellular, forKey: "scanOnCellular") } }
    @Published var scanOnLaunch: Bool { didSet { d.set(scanOnLaunch, forKey: "scanOnLaunch") } }
    @Published var theme: Theme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var artworkLimitBytes: Int { didSet { d.set(artworkLimitBytes, forKey: "reel.artworkLimit") } }
    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    @Published var autoPlayNext: Bool { didSet { d.set(autoPlayNext, forKey: "autoPlayNext") } }

    init() {
        tmdbAPIKey = d.string(forKey: "tmdbAPIKey") ?? ""
        tvdbAPIKey = d.string(forKey: "tvdbAPIKey") ?? ""
        tvdbPIN = d.string(forKey: "tvdbPIN") ?? ""
        animeMatching = d.object(forKey: "animeMatching") as? Bool ?? true
        metadataLanguage = d.string(forKey: "metadataLanguage") ?? "en-GB"
        hardwareDecoding = d.object(forKey: "hardwareDecoding") as? Bool ?? true
        networkCachingMS = d.object(forKey: "networkCachingMS") as? Int ?? 1500
        skipInterval = d.object(forKey: "skipInterval") as? Int ?? 10
        audioLanguage = d.string(forKey: "audioLanguage") ?? "en"
        subtitleLanguage = d.string(forKey: "subtitleLanguage") ?? "en"
        subtitlesOnByDefault = d.bool(forKey: "subtitlesOnByDefault")
        backgroundAudio = d.bool(forKey: "backgroundAudio")
        scanOnCellular = d.bool(forKey: "scanOnCellular")
        scanOnLaunch = d.object(forKey: "scanOnLaunch") as? Bool ?? true
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        artworkLimitBytes = d.object(forKey: "reel.artworkLimit") as? Int ?? 2_000_000_000
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        autoPlayNext = d.object(forKey: "autoPlayNext") as? Bool ?? true
    }

    /// nil until the user has entered a key.
    var tmdb: TMDbClient? {
        guard !tmdbAPIKey.isEmpty else { return nil }
        let region = metadataLanguage.split(separator: "-").count > 1 ? String(metadataLanguage.split(separator: "-")[1]) : "GB"
        return TMDbClient(apiKey: tmdbAPIKey, language: metadataLanguage, region: region)
    }

    /// nil until the user has entered a TheTVDB project key.
    var tvdb: TVDBClient? {
        guard !tvdbAPIKey.isEmpty else { return nil }
        return TVDBClient(apiKey: tvdbAPIKey, pin: tvdbPIN)
    }

    /// Shared so the AniDB and Anime-Lists indexes load once per launch, not once per scan.
    private static let anidb = AniDBTitles()
    private static let animeLists = AnimeLists()

    /// What the matcher may consult: TMDb (required for anything), TheTVDB if keyed, AniDB + Anime-Lists if enabled.
    var providers: MetadataProviders {
        MetadataProviders(tmdb: tmdb, tvdb: tvdb, anidb: animeMatching ? Self.anidb : nil, animeLists: animeMatching ? Self.animeLists : nil)
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"),
        ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"),
    ]
}
