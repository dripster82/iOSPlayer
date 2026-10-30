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
    @State private var confirmReset = false

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
                Toggle(isOn: $settings.animeMatching) {
                    VStack(alignment: .leading) { Text("Anime matching"); Text("AniDB titles + Anime-Lists map fansub names and absolute episode numbers to TMDb. No key needed.").font(.caption).foregroundStyle(.secondary) }
                }
                SecureField("TheTVDB API key (optional)", text: $settings.tvdbAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !settings.tvdbAPIKey.isEmpty {
                    SecureField("TheTVDB subscriber PIN (optional)", text: $settings.tvdbPIN).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField(AppSettings.BuiltIn.fanart.isEmpty ? "fanart.tv API key (optional)" : "fanart.tv personal key (optional, for newer images)", text: $settings.fanartAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("How do I get a key?") { showKeyHelp = true }
                Picker("Metadata language", selection: $settings.metadataLanguage) {
                    ForEach([("en-GB", "English (UK)"), ("en-US", "English (US)"), ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"), ("ja-JP", "Japanese")], id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: { Text("Metadata") } footer: {
                Text(settings.effectiveTMDbKey.isEmpty ? "TMDb is required for titles, artwork and episode names. Free for non-commercial use." : "This product uses the TMDb API but is not endorsed or certified by TMDb. TheTVDB is a fallback search for shows TMDb can't find; a v4 project key is free for personal use at thetvdb.com/api-information. fanart.tv adds logos and extra backgrounds on detail screens; a project key is free at fanart.tv/get-an-api-key.")
            }

            Section {
                SecureField(AppSettings.BuiltIn.openSubtitles.isEmpty ? "OpenSubtitles API key (optional)" : "OpenSubtitles API key (built in · optional)", text: $settings.openSubtitlesAPIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !settings.effectiveOpenSubtitlesKey.isEmpty {
                    TextField("OpenSubtitles username", text: $settings.openSubtitlesUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("OpenSubtitles password", text: $settings.openSubtitlesPassword)
                }
                Picker("Subtitle size", selection: $settings.subtitleScale) {
                    Text("Small").tag(80); Text("Normal").tag(100); Text("Large").tag(130); Text("Huge").tag(170)
                }
                Picker("Subtitle colour", selection: $settings.subtitleColor) {
                    ForEach(AppSettings.subtitleColors, id: \.hex) { Text($0.name).tag($0.hex) }
                }
                Toggle("Box behind subtitles", isOn: $settings.subtitleBackground)
                Toggle(isOn: $settings.subtitleRaised) { VStack(alignment: .leading) { Text("Raise subtitles"); Text("Lifts them above the bottom edge, for letterboxed films.").font(.caption).foregroundStyle(.secondary) } }
            } header: { Text("Subtitles") } footer: {
                Text("Find subtitles online from the player's Subtitles sheet. The API key comes from opensubtitles.com → API consumers (free); downloading needs a free account and has a daily limit. Only the title or TMDb id is sent, never your files.")
            }

            Section("Playback") {
                Toggle(isOn: $settings.hardwareDecoding) { VStack(alignment: .leading) { Text("Hardware decoding"); Text("VideoToolbox. Turn off if a file shows artefacts.").font(.caption).foregroundStyle(.secondary) } }
                Picker("Preferred audio language", selection: $settings.audioLanguage) { ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Picker("Preferred subtitle language", selection: $settings.subtitleLanguage) { ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) } }
                Toggle("Subtitles on by default", isOn: $settings.subtitlesOnByDefault)
                Picker("Skip interval", selection: $settings.skipInterval) { ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) } }
                Picker(selection: $settings.networkCachingMS) { ForEach([500, 1000, 1500, 3000, 5000], id: \.self) { Text("\($0) ms" + ($0 == 3000 ? " (default)" : "")).tag($0) } } label: {
                    VStack(alignment: .leading) { Text("Network buffer"); Text("Raise if streaming stutters. Seeks take longer.").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("Auto-play next episode", isOn: $settings.autoPlayNext)
                if settings.autoPlayNext {
                    Picker("Up Next countdown", selection: $settings.autoPlayCountdown) { ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) } }
                }
                Toggle(isOn: $settings.dialogueBoost) { VStack(alignment: .leading) { Text("Dialogue boost"); Text("Lifts quiet speech and tames loud scenes, for speakers at night. Also in the player's More sheet.").font(.caption).foregroundStyle(.secondary) } }
                Toggle(isOn: $settings.backgroundAudio) { VStack(alignment: .leading) { Text("Play audio in background"); Text("Video pauses, audio continues").font(.caption).foregroundStyle(.secondary) } }
            }

            Section("Library") {
                Toggle(isOn: $settings.scanOnLaunch) { VStack(alignment: .leading) { Text("Scan for new media on launch"); Text("Checks every source when the app opens (at most every 10 minutes). Sources → Refresh all does it on demand.").font(.caption).foregroundStyle(.secondary) } }
                Toggle(isOn: $settings.acceptVLCLinks) { VStack(alignment: .leading) { Text("Accept VLC links"); Text("Lets apps that only know VLC (DS file, some browsers) open streams in Reel through vlc:// links. reel:// links always work.").font(.caption).foregroundStyle(.secondary) } }
                NavigationLink { SourcesView() } label: { Label("Sources", systemImage: "externaldrive.connected.to.line.below") }
                Toggle(isOn: Binding(get: { DemoLibrary.installed(in: library) != nil }, set: { on in if on { DemoLibrary.install(in: library) } else { DemoLibrary.remove(from: library) }; settings.demoInstalled = on })) {
                    VStack(alignment: .leading) { Text("Sample library"); Text("Three short films and a show, built into the app, to try Reel without a server. The titles are invented and the clips are test patterns.").font(.caption).foregroundStyle(.secondary) }
                }
                NavigationLink(value: LibraryRoute.favourites) { Label("Favourites", systemImage: "heart") }
                NavigationLink(value: LibraryRoute.collections) { Label("Collections", systemImage: "rectangle.stack") }
                NavigationLink { NeedsReviewView() } label: { LabeledContent("Needs Review", value: "\(reviewCount) items") }
                NavigationLink { CodecsView() } label: { Label("Codecs and formats", systemImage: "waveform.badge.magnifyingglass") }
                NavigationLink { HiddenItemsView() } label: { LabeledContent("Hidden items", value: "\(hiddenCount)") }
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
                BuildInfoRow()
                NavigationLink("Diagnostics") { DiagnosticsView() }
                NavigationLink("Licences") { LicencesView() }
                NavigationLink("Data providers") { AttributionView() }
                Link(destination: URL(string: "mailto:barley_gilt6r@icloud.com?subject=Reel%20support")!) { Label("Contact support", systemImage: "envelope") }
                Link(destination: URL(string: "https://dripster82.github.io/iOSPlayer/privacy.html")!) { Label("Privacy policy", systemImage: "hand.raised") }
                Link(destination: URL(string: "https://dripster82.github.io/iOSPlayer/terms.html")!) { Label("Terms of use", systemImage: "doc.text") }
            }

            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    Label("Reset Reel", systemImage: "arrow.counterclockwise").foregroundStyle(.red)
                }
            } footer: {
                Text("Removes the library, settings, downloads, caches and sync state from this device, as if the app had just been installed. Nothing in iCloud is touched, and source passwords stay in iCloud Keychain. The app quits; open it again to start over.")
            }
        }
        .confirmationDialog("Reset Reel on this device?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset and quit", role: .destructive) { AppReset.performAndQuit() }
        } message: { Text("Everything stored on this device is removed. Other devices and iCloud are unaffected.") }
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

/// What the player has found in the files it has opened. Nothing is probed during a scan.
struct CodecsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var summary = LibraryStore.CodecSummary()
    var body: some View {
        List {
            Section {
                ForEach(summary.codecs, id: \.name) { c in LabeledContent(c.name, value: "\(c.count)") }
                if summary.codecs.isEmpty { Text("Nothing probed yet. Codecs are read the first time a file plays.").foregroundStyle(.secondary) }
            } header: { Text("Video codecs") } footer: {
                Text("\(summary.probed) files probed, \(summary.unprobed) not played yet. Files are never opened during a scan.")
            }
            Section("From file names") {
                LabeledContent("4K (2160p)", value: "\(summary.uhd)")
                LabeledContent("HDR / Dolby Vision", value: "\(summary.hdr)")
            }
        }
        .navigationTitle("Codecs and formats")
        .refreshFromLibrary { summary = library.codecSummary() }
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
                            ArtworkImage(url: (item.kind == .episode ? item.show : item)?.posterURL ?? item.posterURL, title: item.title, aspect: item.isAudiobookPart || item.kind == .audiobook ? 1 : 2 / 3, cornerRadius: 6).frame(width: 44, height: item.isAudiobookPart || item.kind == .audiobook ? 44 : 66)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind == .episode ? (item.show?.title ?? item.title) : item.title).font(.subheadline.weight(.semibold))
                                if item.kind == .episode, !item.isAudiobookPart { Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Text([item.episodeCode, ws.watched ? "Finished" : ws.progress.map { "\(Int($0 * 100))%" }, ws.lastPlayedAt?.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if states.isEmpty { ContentUnavailableView("No history yet", systemImage: "clock") } }
        .navigationTitle("History")
        .toolbar { Button("Clear") { confirmClear = true }.disabled(states.isEmpty) }
        .searchButton()
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
                    // TMDB's terms ask for an approved logo, smaller than the app's own branding, in About.
                    // Drop TMDB's "blue short" logo into Assets.xcassets as "tmdb-logo"; until then, the name.
                    if UIImage(named: "tmdb-logo") != nil {
                        Image("tmdb-logo").resizable().scaledToFit().frame(height: 22).accessibilityLabel("TMDB")
                    } else {
                        Text("TMDB").font(.headline)
                    }
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB. Film and TV metadata, posters, backdrops and cast information are provided by The Movie Database (themoviedb.org).").font(.footnote)
                    Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org")!).font(.footnote)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("fanart.tv").font(.headline)
                    Text("Logos, clear art, extra backgrounds and alternative posters on detail pages and in Edit artwork are images from fanart.tv, contributed by its community, used under its non-commercial terms. Add your own fanart.tv personal key in Settings → Metadata to see newly approved images sooner.").font(.footnote)
                    Link("fanart.tv", destination: URL(string: "https://fanart.tv")!).font(.footnote)
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

/// Version, build number, and the commit and time the app was built from (stamped into Info.plist by
/// the "Stamp build info" build phase), so a device can be matched to a commit. Tap to copy.
struct BuildInfoRow: View {
    @State private var copied = false
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var version: String { "\(info["CFBundleShortVersionString"] as? String ?? "0.1") (\(info["CFBundleVersion"] as? String ?? "0"))" }
    private var commit: String? { info["ReelGitCommit"] as? String }
    private var branch: String? { info["ReelGitBranch"] as? String }
    private var configuration: String? { info["ReelBuildConfiguration"] as? String }
    private var builtAt: Date? {
        guard let s = info["ReelBuildDate"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
    private var detail: String {
        var parts: [String] = []
        if let commit { parts.append(commit + (commit.hasSuffix("+") ? " (uncommitted changes)" : "")) }
        if let builtAt { parts.append("built " + builtAt.formatted(date: .abbreviated, time: .shortened)) }
        if let configuration, configuration != "Release" { parts.append(configuration) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = "Reel \(version) \(detail)" + (branch.map { " on \($0)" } ?? "")
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build").foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if let branch, branch != "main" { Text(branch).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer()
                Text(copied ? "Copied" : version).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
