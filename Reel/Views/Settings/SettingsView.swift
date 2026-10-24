import SwiftUI
import MediaCore
import Library
import Sync

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: SyncEngine
    @State private var artworkSize: Int64 = 0
    @State private var showKeyHelp = false
    @State private var unmatchedCount = 0
    @State private var reviewCount = 0
    @State private var hiddenCount = 0

    var body: some View {
        Form {
            Section {
                SecureField("TMDb API key (v3)", text: $settings.tmdbAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    // A v3 key is 32 hex characters. The moment a complete one lands, match everything scanned without it.
                    .onChange(of: settings.tmdbAPIKey) { _, key in
                        if key.count == 32, unmatchedCount > 0 { library.scanAll(providers: settings.providers) }
                    }
                if unmatchedCount > 0, settings.tmdb != nil {
                    Button("Match \(unmatchedCount) unmatched files now") { library.scanAll(providers: settings.providers) }
                }
                Toggle(isOn: $settings.animeMatching) {
                    VStack(alignment: .leading) { Text("Anime matching"); Text("AniDB titles + Anime-Lists map fansub names and absolute episode numbers to TMDb. No key needed.").font(.caption).foregroundStyle(.secondary) }
                }
                SecureField("TheTVDB API key (optional)", text: $settings.tvdbAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !settings.tvdbAPIKey.isEmpty {
                    SecureField("TheTVDB subscriber PIN (optional)", text: $settings.tvdbPIN).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField("fanart.tv API key (optional)", text: $settings.fanartAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("How do I get a key?") { showKeyHelp = true }
                Picker("Metadata language", selection: $settings.metadataLanguage) {
                    ForEach([("en-GB", "English (UK)"), ("en-US", "English (US)"), ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"), ("ja-JP", "Japanese")], id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: { Text("Metadata") } footer: {
                Text(settings.tmdbAPIKey.isEmpty ? "TMDb is required for titles, artwork and episode names. Free for non-commercial use." : "This product uses the TMDb API but is not endorsed or certified by TMDb. TheTVDB is a fallback search for shows TMDb can't find; a v4 project key is free for personal use at thetvdb.com/api-information. fanart.tv adds logos and extra backgrounds on detail screens; a project key is free at fanart.tv/get-an-api-key.")
            }

            Section {
                SecureField("OpenSubtitles API key (optional)", text: $settings.openSubtitlesAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !settings.openSubtitlesAPIKey.isEmpty {
                    TextField("OpenSubtitles username", text: $settings.openSubtitlesUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("OpenSubtitles password", text: $settings.openSubtitlesPassword)
                }
            } header: { Text("Subtitles") } footer: {
                Text("Find subtitles online from the player's Subtitles sheet. The API key comes from opensubtitles.com → API consumers (free); downloading needs a free account and has a daily limit. Only the title or TMDb id is sent, never your files.")
            }

            Section("Playback") {
                Toggle(isOn: $settings.hardwareDecoding) { VStack(alignment: .leading) { Text("Hardware decoding"); Text("VideoToolbox. Turn off if a file shows artefacts.").font(.caption).foregroundStyle(.secondary) } }
                Picker("Preferred audio language", selection: $settings.audioLanguage) { ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Picker("Preferred subtitle language", selection: $settings.subtitleLanguage) { ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Toggle("Subtitles on by default", isOn: $settings.subtitlesOnByDefault)
                Picker("Skip interval", selection: $settings.skipInterval) { ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) } }
                Picker(selection: $settings.networkCachingMS) { ForEach([500, 1000, 1500, 3000, 5000], id: \.self) { Text("\($0) ms" + ($0 == 1500 ? " (default)" : "")).tag($0) } } label: {
                    VStack(alignment: .leading) { Text("Network buffer"); Text("Raise if streaming stutters. Seeks take longer.").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("Auto-play next episode", isOn: $settings.autoPlayNext)
                Toggle(isOn: $settings.backgroundAudio) { VStack(alignment: .leading) { Text("Play audio in background"); Text("Video pauses, audio continues").font(.caption).foregroundStyle(.secondary) } }
            }

            Section("Library") {
                Toggle(isOn: $settings.scanOnLaunch) { VStack(alignment: .leading) { Text("Scan for new media on launch"); Text("Checks every source when the app opens (at most every 10 minutes). Sources → Refresh all does it on demand.").font(.caption).foregroundStyle(.secondary) } }
                NavigationLink { SourcesView() } label: { Label("Sources", systemImage: "externaldrive.connected.to.line.below") }
                NavigationLink(value: LibraryRoute.favourites) { Label("Favourites", systemImage: "heart") }
                NavigationLink(value: LibraryRoute.collections) { Label("Collections", systemImage: "rectangle.stack") }
                NavigationLink { NeedsReviewView() } label: { LabeledContent("Needs Review", value: "\(reviewCount) items") }
                NavigationLink { HiddenItemsView() } label: { LabeledContent("Hidden items", value: "\(hiddenCount)") }
                NavigationLink { HistoryView() } label: { Text("Watch history") }
            }

            Section {
                Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0, cloudContainerID: AppSettings.cloudContainerID) })) {
                    VStack(alignment: .leading) { Text("Sync library across your devices"); Text("Sources, the scanned library, watch progress, favourites and fixes. Uses your Apple ID; nothing to sign in to.").font(.caption).foregroundStyle(.secondary) }
                }
                if sync.isEnabled {
                    LabeledContent("Last synced", value: sync.lastSyncedAt?.formatted(.relative(presentation: .named)) ?? "Not yet")
                    let pending = sync.pendingCount
                    if pending > 0 { LabeledContent("Waiting to upload", value: "\(pending)") }
                    Button { Task { await sync.syncNow() } } label: {
                        HStack { Text(sync.isSyncing ? "Syncing…" : "Sync now"); if sync.isSyncing { Spacer(); ProgressView().controlSize(.small) } }
                    }.disabled(sync.isSyncing)
                    if let summary = sync.lastSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                }
                if let e = sync.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            } header: { Text("iCloud") } footer: { Text("Source passwords travel only through iCloud Keychain, never through the app's iCloud data. Files-app folders stay on the device that added them.") }

            Section("Storage") {
                Picker("Artwork cache limit", selection: $settings.artworkLimitBytes) {
                    ForEach([(500_000_000, "500 MB"), (1_000_000_000, "1 GB"), (2_000_000_000, "2 GB"), (5_000_000_000, "5 GB")], id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Artwork cache", value: MediaFormat.bytes(artworkSize))
                Button("Clear artwork cache", role: .destructive) { Task { await ImageLoader.shared.clear(); artworkSize = 0 } }
                NavigationLink { DownloadsView() } label: { LabeledContent("Downloads", value: MediaFormat.bytes(downloads.totalBytes)) }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) { ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")
                NavigationLink("Diagnostics") { DiagnosticsView() }
                NavigationLink("Licences") { LicencesView() }
                NavigationLink("Data providers") { AttributionView() }
            }
        }
        .navigationTitle("Settings")
        .refreshFromLibrary {
            unmatchedCount = library.unmatchedFileCount()
            reviewCount = library.filesNeedingReview().count
            hiddenCount = library.items(kind: .film, includeHidden: true).filter(\.hidden).count + library.items(kind: .show, includeHidden: true).filter(\.hidden).count
        }
        .task { artworkSize = await ImageLoader.shared.sizeOnDisk() }
        .alert("TMDb API key", isPresented: $showKeyHelp) { Button("OK") {} } message: {
            Text("Create a free account at themoviedb.org, open Settings → API, and request a v3 developer key. Personal, non-commercial use is free. Paste the key here.")
        }
    }
}

struct HiddenItemsView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        let hidden = (library.items(kind: .film, includeHidden: true) + library.items(kind: .show, includeHidden: true)).filter(\.hidden)
        List(hidden, id: \.itemKey) { item in
            HStack { Text(item.title); Spacer(); Button("Unhide") { item.hidden = false; try? library.context.save() } }
        }
        .overlay { if hidden.isEmpty { ContentUnavailableView("Nothing hidden", systemImage: "eye") } }
        .navigationTitle("Hidden items")
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var confirmClear = false
    var body: some View {
        let states = library.watchStates().filter { $0.lastPlayedAt != nil }
        List {
            ForEach(states, id: \.itemKey) { ws in
                if let item = library.item(ws.itemKey) {
                    NavigationLink(value: item.itemKey) {
                        HStack(spacing: 12) {
                            ArtworkImage.Placeholder(title: item.title).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(item.kind == .episode ? (item.show?.title ?? item.title) : item.title).font(.subheadline.weight(.semibold))
                                Text([item.episodeCode, ws.watched ? "Finished" : ws.progress.map { "\(Int($0 * 100))%" }, ws.lastPlayedAt?.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if states.isEmpty { ContentUnavailableView("No history yet", systemImage: "clock") } }
        .navigationTitle("Watch history")
        .toolbar { Button("Clear") { confirmClear = true }.disabled(states.isEmpty) }
        .confirmationDialog("Clear watch history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { states.forEach { library.context.delete($0) }; try? library.context.save() }
        }
        .itemNavigation()
    }
}

struct LicencesView: View {
    var body: some View {
        List {
            Section("Playback") {
                licence("VLCKit", "LGPL 2.1", "Dynamically linked. Source: code.videolan.org/videolan/VLCKit. This app does not modify VLCKit; if it ever does, the modified library source will be published.")
                licence("FFmpeg (inside VLCKit)", "LGPL 2.1", "ffmpeg.org")
            }
            Section("Libraries") {
                licence("AMSMB2", "MIT", "github.com/amosavian/AMSMB2")
                licence("KeychainAccess", "MIT", "github.com/kishikawakatsumi/KeychainAccess")
            }
        }.navigationTitle("Licences")
    }
    private func licence(_ name: String, _ kind: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(name).font(.headline); Spacer(); Text(kind).font(.caption.bold()).foregroundStyle(.secondary) }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AttributionView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TMDb").font(.headline)
                    Text("This product uses the TMDb API but is not endorsed or certified by TMDb. Film and TV metadata, posters, backdrops and cast information are provided by The Movie Database (themoviedb.org).").font(.footnote)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("fanart.tv").font(.headline)
                    Text("Logos, clear art and extra backgrounds are provided by fanart.tv (fanart.tv) when a key is set, under its non-commercial terms.").font(.footnote)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AniDB and Anime-Lists").font(.headline)
                    Text("Anime titles are recognised using the AniDB title database (anidb.net), used under its non-commercial terms, and mapped to TMDb seasons and episodes with the community Anime-Lists project (github.com/Anime-Lists/anime-lists).").font(.footnote)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TheTVDB").font(.headline)
                    Text("When a TheTVDB key is set, show lookups that TMDb cannot resolve use metadata provided by TheTVDB (thetvdb.com). Please consider contributing to TheTVDB if you find it useful.").font(.footnote)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Planned").font(.headline)
                    Text("TheTVDB (episode ordering), Fanart.tv (logos and clear art) and OpenSubtitles (subtitle search) are in the plan and will be credited here when they ship.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Data providers")
    }
}
