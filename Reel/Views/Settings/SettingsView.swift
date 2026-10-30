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
    @State private var reviewCount = 0
    @State private var hiddenCount = 0
    @State private var sourceCount = 0
    @State private var confirmReset = false

    var body: some View {
        Form {
            // The library: where the files come from and what is waiting for a decision.
            Section("Library") {
                NavigationLink { SourcesView() } label: { LabeledContent { Text("\(sourceCount)") } label: { Label("Sources", systemImage: "externaldrive.connected.to.line.below") } }
                NavigationLink { NeedsReviewView() } label: { LabeledContent { Text("\(reviewCount)") } label: { Label("Needs Review", systemImage: "questionmark.folder") } }
                NavigationLink { HiddenItemsView() } label: { LabeledContent { Text("\(hiddenCount)") } label: { Label("Hidden items", systemImage: "eye.slash") } }
                NavigationLink { CodecsView() } label: { Label("Codecs and formats", systemImage: "waveform.badge.magnifyingglass") }
                NavigationLink(value: LibraryRoute.favourites) { Label("Favourites", systemImage: "heart") }
                NavigationLink(value: LibraryRoute.collections) { Label("Collections", systemImage: "rectangle.stack") }
            }

            // Preferences, one page each: the top level stays short enough to read in a glance.
            Section("Preferences") {
                NavigationLink { MetadataSettingsView() } label: { settingsRow("Metadata", "TMDb, TheTVDB, fanart.tv, Audible", "text.magnifyingglass") }
                NavigationLink { PlaybackSettingsView() } label: { settingsRow("Playback", "Languages, skipping, Up Next, decoding", "play.circle") }
                NavigationLink { SubtitleSettingsView() } label: { settingsRow("Subtitles", "Size, colour, OpenSubtitles", "captions.bubble") }
                NavigationLink { ScanningSettingsView() } label: { settingsRow("Scanning", "On launch, mobile data, sample library", "arrow.triangle.2.circlepath") }
                Picker(selection: $settings.theme) { ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) } } label: { Label("Theme", systemImage: "circle.lefthalf.filled") }
            }

            Section {
                Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0, cloudContainerID: AppSettings.cloudContainerID) })) {
                    VStack(alignment: .leading) { Text("Sync across your devices"); Text("Sources, the library, watch progress, favourites, collections and fixes. Uses your Apple ID; nothing to sign in to.").font(.caption).foregroundStyle(.secondary) }
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
                NavigationLink { DownloadsView() } label: { LabeledContent("Downloads", value: MediaFormat.bytes(downloads.totalBytes)) }
                Picker("Artwork cache limit", selection: $settings.artworkLimitBytes) {
                    ForEach([(500_000_000, "500 MB"), (1_000_000_000, "1 GB"), (2_000_000_000, "2 GB"), (5_000_000_000, "5 GB")], id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Artwork cache", value: MediaFormat.bytes(artworkSize))
                Button("Clear artwork cache", role: .destructive) { Task { await ImageLoader.shared.clear(); artworkSize = 0 } }
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
                Text("Removes the library, settings, downloads, caches and sync state from this device, as if the app had just been installed. Nothing in iCloud is touched, and source passwords stay in iCloud Keychain. The app quits.")
            }
        }
        .confirmationDialog("Reset Reel on this device?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset and quit", role: .destructive) { AppReset.performAndQuit() }
        } message: { Text("Everything stored on this device is removed. Other devices and iCloud are unaffected.") }
        .navigationTitle("Settings")
        .refreshFromLibrary {
            sourceCount = library.sources().count
            reviewCount = library.filesNeedingReview().count
            hiddenCount = library.items(kind: .film, includeHidden: true).filter(\.hidden).count + library.items(kind: .show, includeHidden: true).filter(\.hidden).count
        }
        .task { artworkSize = await ImageLoader.shared.sizeOnDisk() }
    }

    private func settingsRow(_ title: String, _ detail: String, _ icon: String) -> some View {
        Label { VStack(alignment: .leading, spacing: 2) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: icon) }
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

    /// "Finished", "50%", or where it stopped when the fraction is unknown: a stop in the first half
    /// minute, or a file whose length the player never learned, used to leave this blank.
    static func progressLabel(_ ws: WatchState) -> String {
        if ws.watched { return "Finished" }
        if let p = ws.progress { return "\(Int(p * 100))%" }
        if ws.position > 0 { return "Started · \(MediaFormat.clock(ws.position)) in" }
        return "Started"
    }
    var body: some View {
        let states = library.watchStates().filter { $0.lastPlayedAt != nil }
        List {
            ForEach(states, id: \.itemKey) { ws in
                if let item = library.item(ws.itemKey) {
                    NavigationLink(value: item.itemKey) {
                        HStack(spacing: 12) {
                            let isBook = item.isAudiobookPart || item.kind == .audiobook
                            ArtworkImage(url: (item.kind == .episode ? item.show : item)?.posterURL ?? item.posterURL, title: item.title, aspect: isBook ? 1 : 2 / 3, cornerRadius: 6).frame(width: 44, height: isBook ? 44 : 66)
                                // What kind of thing it was: a show, a film or a book.
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: isBook ? "headphones" : item.kind == .episode ? "tv" : "film")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(3)
                                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(2)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind == .episode ? (item.show?.title ?? item.title) : item.title).font(.subheadline.weight(.semibold))
                                if item.kind == .episode, !item.isAudiobookPart { Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Text([item.episodeCode, Self.progressLabel(ws), ws.lastPlayedAt?.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
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
