import SwiftUI
import MediaCore
import MediaSources
import Library

struct SourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(library.sources(), id: \.id) { s in
                    NavigationLink { SourceDetailView(source: s) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(colour(s.status)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.body.weight(.semibold))
                                Text(subtitle(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } footer: {
                Text("Passwords are kept in the device Keychain and never synced.")
            }
            Section("Library scan") {
                Button { library.scanAll(tmdb: settings.tmdb) } label: { Label("Refresh all sources", systemImage: "arrow.clockwise") }
                    .disabled(library.sources().isEmpty)
                Toggle("Scan on mobile data", isOn: $settings.scanOnCellular)
            }
            if settings.tmdb == nil {
                Section { Label("Add a TMDb API key in Settings to match titles and fetch artwork. Scans still index your files.", systemImage: "exclamationmark.triangle").font(.footnote) }
            }
            if let err = library.lastError {
                Section { Text(err).font(.footnote).foregroundStyle(.red) }
            }
        }
        .overlay { if library.sources().isEmpty { ContentUnavailableView("No sources", systemImage: "externaldrive.badge.plus", description: Text("Add a NAS share, a WebDAV server or a folder on this device.")) } }
        .navigationTitle("Sources")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $adding) { AddSourceView() }
    }

    private func colour(_ s: SourceStatus) -> Color {
        switch s { case .online: .green; case .offline, .authFailed: .red; case .scanning: .yellow; case .unknown: .gray }
    }
    private func subtitle(_ s: SourceRecord) -> String {
        var parts = [s.type.displayName]
        if !s.host.isEmpty { parts.append(s.host) }
        parts.append("\(s.files.filter { !$0.ignored }.count) items")
        if let p = library.scanProgress[s.id], p.phase != .done, p.phase != .failed { parts.append("Scanning \(p.filesSeen)…") }
        else if let d = s.lastScan { parts.append("Scanned " + d.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

struct SourceDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord
    @State private var confirmRemove = false
    @State private var tagging: FolderPath?
    @State private var editing = false

    var body: some View {
        List {
            Section {
                switch source.status {
                case .offline: Banner(colour: .red, text: "Can't reach \(source.host). Last scan \(source.lastScan?.formatted(.relative(presentation: .named)) ?? "never").") { Button("Retry") { library.scan(source, tmdb: settings.tmdb) } }
                case .authFailed: Banner(colour: .red, text: "Password rejected.") { Button("Edit") { editing = true } }
                default: Banner(colour: .green, text: "\(source.type.displayName) · \(source.host.isEmpty ? source.name : source.host)") { Button(library.isScanning(source.id) ? "Scanning…" : "Rescan") { library.scan(source, tmdb: settings.tmdb) }.disabled(library.isScanning(source.id)) }
                }
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)

            Section("Folders · tap to tag") {
                ForEach(source.folderRules.sorted { $0.folderPath < $1.folderPath }, id: \.folderPath) { rule in
                    Button { tagging = FolderPath(rule.folderPath) } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(rule.folderPath.isEmpty ? "/" : rule.folderPath).foregroundStyle(.primary)
                            Spacer()
                            TagPill(tag: rule.tag)
                        }
                    }
                }
                NavigationLink { FileBrowserView(source: source, path: "", tagging: true) } label: { Label("Add a folder…", systemImage: "plus") }
            }
            Section("Browse") {
                NavigationLink { FileBrowserView(source: source, path: "") } label: {
                    VStack(alignment: .leading) { Text("Browse files"); Text("Plain file view. Play anything, even if it isn't in the library.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Connection") {
                LabeledContent("Protocol", value: source.type.displayName)
                if !source.host.isEmpty { LabeledContent("Host", value: source.host) }
                if source.type != .local { LabeledContent("Share / path", value: source.path) }
                if let u = source.username { LabeledContent("Username", value: u) }
                if source.type != .local { Button("Edit credentials") { editing = true } }
            }
            Section {
                Toggle("Hide this source from the library", isOn: Binding(get: { source.hiddenFromLibrary }, set: { source.hiddenFromLibrary = $0; try? library.context.save() }))
                Button("Remove source", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(source.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove source and its library items", role: .destructive) { try? library.removeSource(source); dismiss() }
        } message: { Text("Watch history and favourites are kept. Files on the drive are not touched.") }
        .sheet(item: $tagging) { folder in TagSheet(source: source, folder: folder.path) }
        .sheet(isPresented: $editing) { AddSourceView(editing: source) }
    }
}

/// Wraps a relative folder path so it can drive `.sheet(item:)` without conforming `String` to `Identifiable`.
struct FolderPath: Identifiable, Hashable {
    let path: String
    var id: String { path }
    init(_ path: String) { self.path = path }
}

struct TagPill: View {
    let tag: FolderTag?
    var body: some View {
        Text(label).font(.caption2.bold()).textCase(.uppercase).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(colour)
    }
    private var label: String { switch tag { case .tv: "TV"; case .films: "Films"; case .mixed: "Mixed"; case .excluded: "Excluded"; case nil: "Untagged" } }
    private var colour: Color { switch tag { case .tv: .blue; case .films: Color.accentColor; case .mixed: .purple; case .excluded: .red; case nil: .secondary } }
}

struct TagSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord
    let folder: String
    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("TV shows", .tv); row("Films", .films); row("Mixed · decide per file", .mixed); row("Not media · exclude", .excluded)
                } header: { Text(folder.isEmpty ? "/" : folder) } footer: { Text("Overrides the filename guess for everything in this folder.") }
                Section { Button("Remove tag", role: .destructive) { try? library.setTag(nil, folder: folder, on: source); dismiss() } }
            }
            .navigationTitle("Folder tag").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }.presentationDetents([.medium])
    }
    private func row(_ title: String, _ tag: FolderTag) -> some View {
        let current = source.folderRules.first { $0.folderPath == folder }?.tag
        return Button { try? library.setTag(tag, folder: folder, on: source); dismiss() } label: {
            HStack { Text(title).foregroundStyle(.primary); Spacer(); if current == tag { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }
        }
    }
}

/// Plain directory listing for a source. Plays files directly, and doubles as the folder picker when `tagging`.
struct FileBrowserView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerCoordinator
    let source: SourceRecord
    let path: String
    var tagging = false
    @State private var entries: [DirectoryEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var tagTarget: FolderPath?

    var body: some View {
        List {
            if tagging {
                Button { tagTarget = FolderPath(path) } label: { Label("Tag this folder (\(path.isEmpty ? "/" : path))", systemImage: "tag") }
            }
            ForEach(entries, id: \.relativePath) { e in
                if e.isDirectory {
                    NavigationLink { FileBrowserView(source: source, path: e.relativePath, tagging: tagging) } label: {
                        Label(e.name, systemImage: "folder").foregroundStyle(.primary)
                    }
                    .swipeActions { Button("Tag") { tagTarget = FolderPath(e.relativePath) }.tint(.accentColor) }
                } else {
                    Button { play(e) } label: {
                        HStack {
                            Image(systemName: e.isVideo ? "film" : e.isSubtitle ? "captions.bubble" : "doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(e.name).foregroundStyle(.primary).lineLimit(2)
                                Text([e.size.map(MediaFormat.bytes), e.isSubtitle ? "Subtitle sidecar" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if e.isVideo { Image(systemName: "play.fill").foregroundStyle(.secondary) }
                        }
                    }.disabled(!e.isVideo)
                }
            }
        }
        .overlay {
            if loading { ProgressView() }
            else if let error { ContentUnavailableView("Can't list folder", systemImage: "wifi.exclamationmark", description: Text(error)) }
            else if entries.isEmpty { ContentUnavailableView("Empty folder", systemImage: "folder") }
        }
        .navigationTitle(path.isEmpty ? source.path.isEmpty ? source.name : (source.path as NSString).lastPathComponent : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $tagTarget) { TagSheet(source: source, folder: $0.path) }
    }

    private func load() async {
        loading = true
        let src = SourceFactory.make(source.config)
        do {
            try await src.connect(credentials: CredentialStore.shared.load(for: source.id))
            entries = try await src.list(path).filter { $0.isDirectory || $0.isVideo || $0.isSubtitle }
            await src.disconnect()
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func play(_ e: DirectoryEntry) {
        // Prefer the library's record so progress is saved against the right item.
        if let f = source.files.first(where: { $0.relativePath == e.relativePath }) {
            if let item = f.item { player.play(item, file: f, settings: settings) } else { player.playFile(f, settings: settings) }
        } else {
            let f = MediaFile(relativePath: e.relativePath, size: e.size ?? 0, modified: e.modified, source: source)
            library.context.insert(f)
            player.playFile(f, settings: settings)
        }
    }
}
