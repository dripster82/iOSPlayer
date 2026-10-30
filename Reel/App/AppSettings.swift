import SwiftUI
import Metadata
import Library
import MediaSources

/// User preferences. Everything here is per-device; nothing syncs.
/// `@Published` + `didSet` rather than `@AppStorage`, because `@AppStorage` doesn't notify an ObservableObject's subscribers.
@MainActor
final class AppSettings: ObservableObject {
    static let cloudContainerID = "iCloud.uk.co.ketelle.reel"
    /// The one instance the app makes at launch, for code that has no view to read it from.
    static var current: AppSettings!

    enum Theme: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
        var colorScheme: ColorScheme? { switch self { case .system: nil; case .dark: .dark; case .light: .light } }
        var title: String { rawValue.capitalized }
    }

    private let d = UserDefaults.standard

    /// Keys the app ships with (Secrets.xcconfig → Info.plist), used when the matching Settings field
    /// is empty. Never shown; never logged.
    enum BuiltIn {
        static let tmdb = value("REEL_TMDB_KEY")
        static let fanart = value("REEL_FANART_KEY")
        static let openSubtitles = value("REEL_OPENSUBTITLES_KEY")
        private static func value(_ key: String) -> String {
            var v = (Bundle.main.infoDictionary?[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // xcconfig keeps quotes written round a value, and a quoted key is refused by every service.
            while v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
            return v.hasPrefix("$(") ? "" : v   // an unexpanded placeholder means no key was configured
        }
    }
    /// The key in use for each service: the user's own if typed, else the built-in one.
    var effectiveTMDbKey: String { tmdbAPIKey.isEmpty ? BuiltIn.tmdb : tmdbAPIKey }
    var effectiveFanartKey: String { fanartAPIKey.isEmpty ? BuiltIn.fanart : fanartAPIKey }
    var effectiveOpenSubtitlesKey: String { openSubtitlesAPIKey.isEmpty ? BuiltIn.openSubtitles : openSubtitlesAPIKey }

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
    /// Audible store the audiobook catalogue lookups use ("uk", "us", …): editions and narrators differ between stores.
    @Published var audibleRegion: String { didSet { d.set(audibleRegion, forKey: "audibleRegion") } }
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
    /// Answer VLC's own link schemes (vlc://, vlcx://, vlc-x-callback://) so apps that only know how
    /// to hand a stream to VLC (DS file) can hand it to Reel. Off by default: they are VLC's schemes.
    @Published var acceptVLCLinks: Bool { didSet { d.set(acceptVLCLinks, forKey: "acceptVLCLinks") } }
    /// The sample library has been installed (Try with sample media).
    @Published var demoInstalled: Bool { didSet { d.set(demoInstalled, forKey: "demoInstalled") } }
    /// Seconds shown on the Up Next card before the next episode starts on its own.
    @Published var autoPlayCountdown: Int { didSet { d.set(autoPlayCountdown, forKey: "autoPlayCountdown") } }

    init() {
        defer { AppSettings.current = self }
        tmdbAPIKey = d.string(forKey: "tmdbAPIKey") ?? ""
        tvdbAPIKey = d.string(forKey: "tvdbAPIKey") ?? ""
        tvdbPIN = d.string(forKey: "tvdbPIN") ?? ""
        fanartAPIKey = d.string(forKey: "fanartAPIKey") ?? ""
        openSubtitlesAPIKey = d.string(forKey: "openSubtitlesAPIKey") ?? ""
        openSubtitlesUsername = d.string(forKey: "openSubtitlesUsername") ?? ""
        openSubtitlesPassword = CredentialStore.shared.load(for: Self.openSubtitlesCredentialID)?.password ?? ""
        animeMatching = d.object(forKey: "animeMatching") as? Bool ?? true
        metadataLanguage = d.string(forKey: "metadataLanguage") ?? "en-GB"
        audibleRegion = d.string(forKey: "audibleRegion") ?? "uk"
        hardwareDecoding = d.object(forKey: "hardwareDecoding") as? Bool ?? true
        networkCachingMS = d.object(forKey: "networkCachingMS") as? Int ?? 3000
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
        acceptVLCLinks = d.bool(forKey: "acceptVLCLinks")
        demoInstalled = d.bool(forKey: "demoInstalled")
        autoPlayCountdown = d.object(forKey: "autoPlayCountdown") as? Int ?? 10
    }

    /// nil until the user has entered a key.
    var tmdb: TMDbClient? {
        let key = effectiveTMDbKey
        guard !key.isEmpty else { return nil }
        let region = metadataLanguage.split(separator: "-").count > 1 ? String(metadataLanguage.split(separator: "-")[1]) : "GB"
        return TMDbClient(apiKey: key, language: metadataLanguage, region: region)
    }

    /// nil until the user has entered a TheTVDB project key.
    var tvdb: TVDBClient? {
        guard !tvdbAPIKey.isEmpty else { return nil }
        return TVDBClient(apiKey: tvdbAPIKey, pin: tvdbPIN)
    }

    /// nil until the user has entered a fanart.tv project key.
    /// fanart.tv wants the project key on every request and the user's personal key sent alongside
    /// it, never instead. Without a shipped project key (a development build) the user's key is all
    /// there is and goes in the project slot.
    var fanart: FanartClient? {
        if !BuiltIn.fanart.isEmpty { return FanartClient(apiKey: BuiltIn.fanart, clientKey: fanartAPIKey, language: metadataLanguage) }
        guard !fanartAPIKey.isEmpty else { return nil }
        return FanartClient(apiKey: fanartAPIKey, language: metadataLanguage)
    }

    /// nil until the user has entered an OpenSubtitles API key. Searching works with the key alone.
    var openSubtitles: OpenSubtitlesClient? {
        let key = effectiveOpenSubtitlesKey
        guard !key.isEmpty else { return nil }
        return OpenSubtitlesClient(apiKey: key, username: openSubtitlesUsername, password: openSubtitlesPassword)
    }

    /// Shared so the AniDB and Anime-Lists indexes load once per launch, not once per scan.
    private static let anidb = AniDBTitles()
    private static let animeLists = AnimeLists()
    private static let wikidata = WikidataClient()
    private static let tvmaze = TVmazeClient()
    private static let kitsu = KitsuClient()

    /// What the matcher may consult: TMDb (required for anything), TheTVDB if keyed, AniDB + Anime-Lists if enabled.
    var providers: MetadataProviders {
        MetadataProviders(tmdb: tmdb, tvdb: tvdb, anidb: animeMatching ? Self.anidb : nil, animeLists: animeMatching ? Self.animeLists : nil,
                          wikidata: Self.wikidata, tvmaze: Self.tvmaze, kitsu: animeMatching ? Self.kitsu : nil)
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"),
        ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"),
    ]
}
