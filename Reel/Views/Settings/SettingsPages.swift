import SwiftUI
import MediaCore
import Library
import Metadata

/// Settings → Metadata: the databases that name titles and supply artwork, and the language they answer in.
struct MetadataSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @State private var showKeyHelp = false
    @State private var unmatchedCount = 0

    var body: some View {
        Form {
            Section {
                SecureField(AppSettings.BuiltIn.tmdb.isEmpty ? "TMDb API key (v3)" : "TMDb API key (built in · optional override)", text: $settings.tmdbAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    // A v3 key is 32 hex characters. The moment a complete one lands, match everything scanned without it.
                    .onChange(of: settings.tmdbAPIKey) { _, key in
                        if key.count == 32, unmatchedCount > 0 { library.scanAll(providers: settings.providers) }
                    }
                if unmatchedCount > 0, settings.tmdb != nil {
                    Button("Match \(unmatchedCount) unmatched files now") { library.scanAll(providers: settings.providers) }
                }
                Button("How do I get a key?") { showKeyHelp = true }
                Picker("Language", selection: $settings.metadataLanguage) {
                    ForEach([("en-GB", "English (UK)"), ("en-US", "English (US)"), ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"), ("ja-JP", "Japanese")], id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: { Text("Films and TV") } footer: {
                Text(settings.effectiveTMDbKey.isEmpty ? "TMDb is required for titles, artwork and episode names. Free for non-commercial use." : "This product uses the TMDb API but is not endorsed or certified by TMDb.")
            }

            Section {
                Toggle(isOn: $settings.animeMatching) {
                    VStack(alignment: .leading) { Text("Anime matching"); Text("AniDB titles and Anime-Lists map fansub names and absolute episode numbers to TMDb. No key needed.").font(.caption).foregroundStyle(.secondary) }
                }
                SecureField("TheTVDB API key (optional)", text: $settings.tvdbAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !settings.tvdbAPIKey.isEmpty {
                    SecureField("TheTVDB subscriber PIN (optional)", text: $settings.tvdbPIN).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField(AppSettings.BuiltIn.fanart.isEmpty ? "fanart.tv API key (optional)" : "fanart.tv personal key (optional, for newer images)", text: $settings.fanartAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("More sources") } footer: {
                Text("TheTVDB adds episode names and artwork TMDb lacks; fanart.tv supplies logos and extra posters. Wikidata, TVmaze and Kitsu are consulted without a key when TMDb's answer is weak.")
            }

            Section {
                Picker("Audible store", selection: $settings.audibleRegion) {
                    ForEach(AudibleCatalogClient.regions, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: { Text("Audiobooks") } footer: {
                Text("Books are looked up in Audible's catalogue (author, narrator, series, summary, cover), with Audnexus and Apple Books behind it. Editions and narrators differ between stores, so pick the one your books came from. No key needed.")
            }
        }
        .navigationTitle("Metadata")
        .refreshFromLibrary { unmatchedCount = library.unmatchedFileCount() }
        .alert("TMDb API key", isPresented: $showKeyHelp) { Button("OK") {} } message: {
            Text("Create a free account at themoviedb.org, open Settings → API, and request a v3 developer key. Personal, non-commercial use is free. Paste the key here.")
        }
    }
}

/// Settings → Playback: decoding, languages, skipping, buffering, what happens at the end of an episode.
struct PlaybackSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Languages") {
                Picker("Preferred audio", selection: $settings.audioLanguage) { ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Picker("Preferred subtitles", selection: $settings.subtitleLanguage) { ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Toggle("Subtitles on by default", isOn: $settings.subtitlesOnByDefault)
            }
            Section("Controls") {
                Picker("Skip interval", selection: $settings.skipInterval) { ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) } }
                Toggle("Auto-play next episode", isOn: $settings.autoPlayNext)
                if settings.autoPlayNext {
                    Picker("Up Next countdown", selection: $settings.autoPlayCountdown) { ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) } }
                }
            }
            Section {
                Toggle(isOn: $settings.dialogueBoost) { VStack(alignment: .leading) { Text("Dialogue boost"); Text("Lifts quiet speech and tames loud scenes, for speakers at night. Also in the player's More sheet.").font(.caption).foregroundStyle(.secondary) } }
                Toggle(isOn: $settings.backgroundAudio) { VStack(alignment: .leading) { Text("Play audio in background"); Text("Video pauses, audio continues.").font(.caption).foregroundStyle(.secondary) } }
            } header: { Text("Sound") }
            Section {
                Toggle(isOn: $settings.hardwareDecoding) { VStack(alignment: .leading) { Text("Hardware decoding"); Text("VideoToolbox. Turn off if a file shows artefacts.").font(.caption).foregroundStyle(.secondary) } }
                Picker(selection: $settings.networkCachingMS) { ForEach([500, 1000, 1500, 3000, 5000], id: \.self) { Text("\($0) ms" + ($0 == 3000 ? " (default)" : "")).tag($0) } } label: {
                    VStack(alignment: .leading) { Text("Network buffer"); Text("Raise if streaming stutters. Seeks take longer.").font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("Engine") }
        }
        .navigationTitle("Playback")
    }
}

/// Settings → Subtitles: how they look, and the OpenSubtitles account for finding them.
struct SubtitleSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Size", selection: $settings.subtitleScale) {
                    Text("Small").tag(80); Text("Normal").tag(100); Text("Large").tag(130); Text("Huge").tag(170)
                }
                Picker("Colour", selection: $settings.subtitleColor) {
                    ForEach(AppSettings.subtitleColors, id: \.hex) { Text($0.name).tag($0.hex) }
                }
                Toggle("Box behind subtitles", isOn: $settings.subtitleBackground)
                Toggle(isOn: $settings.subtitleRaised) { VStack(alignment: .leading) { Text("Raise subtitles"); Text("Lifts them above the bottom edge, for letterboxed films.").font(.caption).foregroundStyle(.secondary) } }
            }
            Section {
                SecureField(AppSettings.BuiltIn.openSubtitles.isEmpty ? "OpenSubtitles API key (optional)" : "OpenSubtitles API key (built in · optional)", text: $settings.openSubtitlesAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !settings.effectiveOpenSubtitlesKey.isEmpty {
                    TextField("OpenSubtitles username", text: $settings.openSubtitlesUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("OpenSubtitles password", text: $settings.openSubtitlesPassword)
                }
            } header: { Text("Finding subtitles") } footer: {
                Text("Search from the player's Subtitles sheet. The API key comes from opensubtitles.com → API consumers (free); downloading needs a free account and has a daily limit. Only the title or TMDb id is sent.")
            }
        }
        .navigationTitle("Subtitles")
    }
}

/// Settings → Scanning: when the library looks for new files, and the links other apps may hand over.
struct ScanningSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.scanOnLaunch) { VStack(alignment: .leading) { Text("Scan on launch"); Text("Checks every source when the app opens, at most every 10 minutes. Sources → Refresh all does it on demand.").font(.caption).foregroundStyle(.secondary) } }
                Toggle(isOn: $settings.scanOnCellular) { VStack(alignment: .leading) { Text("Scan on mobile data"); Text("Background scans otherwise wait for Wi-Fi.").font(.caption).foregroundStyle(.secondary) } }
            } header: { Text("When") } footer: {
                Text("Scans list the folders of each source and read nothing from the files; lengths and codecs are probed afterwards, a few files at a time, and skipped in Low Power Mode. A file missing from three scans running is treated as gone.")
            }
            Section {
                Toggle(isOn: Binding(get: { DemoLibrary.installed(in: library) != nil }, set: { on in if on { DemoLibrary.install(in: library) } else { DemoLibrary.remove(from: library) }; settings.demoInstalled = on })) {
                    VStack(alignment: .leading) { Text("Sample library"); Text("Three short films and a show, built into the app, to try Reel without a server. The titles are invented and the clips are test patterns.").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle(isOn: $settings.acceptVLCLinks) { VStack(alignment: .leading) { Text("Accept VLC links"); Text("Lets apps that only know VLC (DS file, some browsers) open streams in Reel through vlc:// links. reel:// links always work.").font(.caption).foregroundStyle(.secondary) } }
            } header: { Text("Other") }
        }
        .navigationTitle("Scanning")
    }
}
