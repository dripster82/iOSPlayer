import SwiftUI
import Metadata
import Library
import MediaSources

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
    @Published var fanartAPIKey: String { didSet { d.set(fanartAPIKey, forKey: "fanartAPIKey") } }
    @Published var openSubtitlesAPIKey: String { didSet { d.set(openSubtitlesAPIKey, forKey: "openSubtitlesAPIKey") } }
    @Published var openSubtitlesUsername: String { didSet { d.set(openSubtitlesUsername, forKey: "openSubtitlesUsername") } }
    /// Kept in the Keychain (with the source passwords), not in UserDefaults.
    @Published var openSubtitlesPassword: String {
        didSet {
            if openSubtitlesPassword.isEmpty { CredentialStore.shared.remove(for: Self.openSubtitlesCredentialID) }
            else { try? CredentialStore.shared.save(Credentials(username: openSubtitlesUsername, password: openSubtitlesPassword), for: Self.openSubtitlesCredentialID) }
        }
    }
    private static let openSubtitlesCredentialID = UUID(uuidString: "6F9B2E1C-5D0A-4C4B-9A1E-0B5E4C3D2A11")!
    @Published var animeMatching: Bool { didSet { d.set(animeMatching, forKey: "animeMatching") } }
    @Published var metadataLanguage: String { didSet { d.set(metadataLanguage, forKey: "metadataLanguage") } }
    @Published var hardwareDecoding: Bool { didSet { d.set(hardwareDecoding, forKey: "hardwareDecoding") } }
    @Published var networkCachingMS: Int { didSet { d.set(networkCachingMS, forKey: "networkCachingMS") } }
    @Published var skipInterval: Int { didSet { d.set(skipInterval, forKey: "skipInterval") } }
    @Published var audioLanguage: String { didSet { d.set(audioLanguage, forKey: "audioLanguage") } }
    @Published var subtitleLanguage: String { didSet { d.set(subtitleLanguage, forKey: "subtitleLanguage") } }
    @Published var subtitlesOnByDefault: Bool { didSet { d.set(subtitlesOnByDefault, forKey: "subtitlesOnByDefault") } }
    @Published var subtitleScale: Int { didSet { d.set(subtitleScale, forKey: "subtitleScale") } }
    @Published var subtitleColor: String { didSet { d.set(subtitleColor, forKey: "subtitleColor") } }
    @Published var subtitleBackground: Bool { didSet { d.set(subtitleBackground, forKey: "subtitleBackground") } }
    @Published var subtitleRaised: Bool { didSet { d.set(subtitleRaised, forKey: "subtitleRaised") } }
    static let subtitleColors: [(name: String, hex: String)] = [("White", "FFFFFF"), ("Yellow", "FFE94A"), ("Cyan", "7FE8FF"), ("Light grey", "D9D9D9")]
    @Published var backgroundAudio: Bool { didSet { d.set(backgroundAudio, forKey: "backgroundAudio") } }
    @Published var scanOnCellular: Bool { didSet { d.set(scanOnCellular, forKey: "scanOnCellular") } }
    @Published var scanOnLaunch: Bool { didSet { d.set(scanOnLaunch, forKey: "scanOnLaunch") } }
    @Published var theme: Theme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var artworkLimitBytes: Int { didSet { d.set(artworkLimitBytes, forKey: "reel.artworkLimit") } }
    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    @Published var autoPlayNext: Bool { didSet { d.set(autoPlayNext, forKey: "autoPlayNext") } }
    @Published var dialogueBoost: Bool { didSet { d.set(dialogueBoost, forKey: "dialogueBoost") } }
    /// Seconds shown on the Up Next card before the next episode starts on its own.
    @Published var autoPlayCountdown: Int { didSet { d.set(autoPlayCountdown, forKey: "autoPlayCountdown") } }

    init() {
        tmdbAPIKey = d.string(forKey: "tmdbAPIKey") ?? ""
        tvdbAPIKey = d.string(forKey: "tvdbAPIKey") ?? ""
        tvdbPIN = d.string(forKey: "tvdbPIN") ?? ""
        fanartAPIKey = d.string(forKey: "fanartAPIKey") ?? ""
        openSubtitlesAPIKey = d.string(forKey: "openSubtitlesAPIKey") ?? ""
        openSubtitlesUsername = d.string(forKey: "openSubtitlesUsername") ?? ""
        openSubtitlesPassword = CredentialStore.shared.load(for: Self.openSubtitlesCredentialID)?.password ?? ""
        animeMatching = d.object(forKey: "animeMatching") as? Bool ?? true
        metadataLanguage = d.string(forKey: "metadataLanguage") ?? "en-GB"
        hardwareDecoding = d.object(forKey: "hardwareDecoding") as? Bool ?? true
        networkCachingMS = d.object(forKey: "networkCachingMS") as? Int ?? 1500
        skipInterval = d.object(forKey: "skipInterval") as? Int ?? 10
        audioLanguage = d.string(forKey: "audioLanguage") ?? "en"
        subtitleLanguage = d.string(forKey: "subtitleLanguage") ?? "en"
        subtitlesOnByDefault = d.bool(forKey: "subtitlesOnByDefault")
        subtitleScale = d.object(forKey: "subtitleScale") as? Int ?? 100
        subtitleColor = d.string(forKey: "subtitleColor") ?? "FFFFFF"
        subtitleBackground = d.bool(forKey: "subtitleBackground")
        subtitleRaised = d.bool(forKey: "subtitleRaised")
        backgroundAudio = d.bool(forKey: "backgroundAudio")
        scanOnCellular = d.bool(forKey: "scanOnCellular")
        scanOnLaunch = d.object(forKey: "scanOnLaunch") as? Bool ?? true
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        artworkLimitBytes = d.object(forKey: "reel.artworkLimit") as? Int ?? 2_000_000_000
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        autoPlayNext = d.object(forKey: "autoPlayNext") as? Bool ?? true
        dialogueBoost = d.bool(forKey: "dialogueBoost")
        autoPlayCountdown = d.object(forKey: "autoPlayCountdown") as? Int ?? 10
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

    /// nil until the user has entered a fanart.tv project key.
    var fanart: FanartClient? {
        guard !fanartAPIKey.isEmpty else { return nil }
        return FanartClient(apiKey: fanartAPIKey, language: metadataLanguage)
    }

    /// nil until the user has entered an OpenSubtitles API key. Searching works with the key alone.
    var openSubtitles: OpenSubtitlesClient? {
        guard !openSubtitlesAPIKey.isEmpty else { return nil }
        return OpenSubtitlesClient(apiKey: openSubtitlesAPIKey, username: openSubtitlesUsername, password: openSubtitlesPassword)
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
