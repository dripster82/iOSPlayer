import SwiftUI
import UniformTypeIdentifiers
import MediaCore
import MediaSources
import Library

/// Type → (discovered | manual form) → Test Connection → folders → scan. Also used to edit credentials.
/// The form can list a server's SMB shares, or browse another server's folders, to fill the path;
/// the folders step walks into sub-folders so a library folder can sit at any depth.
struct AddSourceView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = SourceDiscovery()
    var editing: SourceRecord? = nil
    var onComplete: (() -> Void)? = nil

    enum Step { case type, form, folders }
    @State private var step: Step = .type
    @State private var type: SourceType = .smb
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var path = ""
    @State private var useTLS = true
    @State private var username = ""
    @State private var password = ""
    @State private var macAddress = ""
    @State private var testing = false
    @State private var error: String?
    @State private var rootEntries: [DirectoryEntry] = []
    @State private var picked: [String: FolderTag] = [:]
    @State private var showPicker = false
    @State private var localBookmark: String?
    /// Connected through Test Connection and kept for the folders step, so each level can list itself.
    @State private var folderSource: (any MediaSource)?
    @State private var nav: [BrowseFolder] = []
    /// The server's SMB shares, offered when the share name is blank or Choose is tapped.
    @State private var shares: [String]?
    /// A connection to a non-SMB server's top level, for browsing to the folder that becomes the path.
    @State private var browsing: BrowseSession?
    private struct BrowseSession: Identifiable { let id = UUID(); let source: any MediaSource }

    var body: some View {
        NavigationStack(path: $nav) {
            Group {
                switch step {
                case .type: typeStep
                case .form: formStep
                case .folders: foldersStep
                }
            }
            .navigationDestination(for: BrowseFolder.self) { fp in
                if let folderSource { FolderBrowser(source: folderSource, path: fp.path, mode: .tick($picked, done: save), nav: $nav) }
            }
            .navigationTitle(editing == nil ? "Add Source" : "Edit Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if step == .form && editing == nil { ToolbarItem(placement: .navigation) { Button { step = .type } label: { Image(systemName: "chevron.left") } } }
            }
        }
        .onAppear {
            if let e = editing {
                type = e.type; name = e.name; host = e.host; port = e.port.map(String.init) ?? ""; path = e.path; useTLS = e.useTLS
                username = e.username ?? ""; password = CredentialStore.shared.load(for: e.id)?.password ?? ""
                macAddress = e.macAddress ?? ""
                step = .form
            } else { discovery.start() }
        }
        .onDisappear { discovery.stop(); let s = folderSource; folderSource = nil; Task { await s?.disconnect() } }
        .sheet(item: $browsing) { session in
            NavigationStack(path: $nav) {
                FolderBrowser(source: session.source, path: "", mode: .chooseOne { chosen in
                    path = chosen.isEmpty ? (type == .webdav ? "/" : "/") : "/" + chosen
                    browsing = nil; nav = []
                    Task { await session.source.disconnect() }
                }, nav: $nav)
                .navigationDestination(for: BrowseFolder.self) { fp in
                    FolderBrowser(source: session.source, path: fp.path, mode: .chooseOne { chosen in
                        path = "/" + chosen
                        browsing = nil; nav = []
                        Task { await session.source.disconnect() }
                    }, nav: $nav)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { browsing = nil; nav = []; Task { await session.source.disconnect() } } } }
            }
        }
        .sheet(isPresented: Binding(get: { shares != nil }, set: { if !$0 { shares = nil } })) {
            NavigationStack {
                List {
                    Section {
                        ForEach(shares ?? [], id: \.self) { share in
                            Button { path = share; shares = nil; Task { await test() } } label: { Label(share, systemImage: "externaldrive.connected.to.line.below").foregroundStyle(.primary) }
                        }
                        if shares?.isEmpty == true { Text("The server lists no shares for this sign-in.").font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text("Shares on \(host)") } footer: { Text("Pick the share that holds your films and shows. The folders inside it come next.") }
                }
                .navigationTitle("Choose a share").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { shares = nil } } }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, let data = try? LocalSource.bookmarkData(for: url) {
                type = .local; name = url.lastPathComponent; host = ""; path = data.base64EncodedString()
                Task { await loadFolders() }
            }
        }
    }

    // MARK: Steps

    private var typeStep: some View {
        List {
            Section("On this device") {
                Button { showPicker = true } label: {
                    Label { VStack(alignment: .leading) { Text("Files, USB or iCloud Drive").foregroundStyle(.primary); Text("Pick a folder with the Files picker").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "folder") }
                }
            }
            Section {
                if let status = discovery.sweepStatus {
                    HStack { ProgressView(); Text(status).font(.footnote).foregroundStyle(.secondary) }
                } else if discovery.hosts.isEmpty {
                    Text("Nothing answered. Make sure this device is on the same Wi-Fi as the server, then scan again or enter it below.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(discovery.hosts) { h in
                    Button { type = h.type; name = h.name; host = h.host; path = h.path; port = h.port.map(String.init) ?? ""; step = .form } label: {
                        HStack { Circle().fill(.green).frame(width: 9, height: 9); VStack(alignment: .leading) { Text(h.name).foregroundStyle(.primary); Text(h.host).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(h.type.displayName).font(.caption2.bold()).foregroundStyle(.secondary) }
                    }
                }
                if discovery.sweepStatus == nil {
                    Button { discovery.sweepSubnet() } label: { Label("Scan the network again", systemImage: "arrow.clockwise") }
                }
            } header: { Text("Found on your network") } footer: { Text("Servers that announce themselves (Bonjour) and every address on this Wi-Fi network checked for SMB, FTP, SFTP, NFS, WebDAV and DLNA.") }
            Section("Or enter manually") {
                ForEach([SourceType.smb, .webdav, .ftp, .sftp, .nfs, .dlna]) { t in
                    Button { type = t; step = .form } label: { HStack { Text(t.displayName).foregroundStyle(.primary); Spacer(); Text(t.formHint).font(.caption2).foregroundStyle(.secondary) } }
                }
            }
        }
    }

    private var formStep: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Living room NAS"))
                TextField("Host or IP", text: $host, prompt: Text("192.168.1.20 or nas.local")).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                HStack {
                    TextField(type.pathLabel, text: $path, prompt: Text(type.pathPrompt)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if type != .dlna && type != .local {
                        Button(type == .smb ? "Shares…" : "Browse…") { Task { await browseForPath() } }.disabled(testing || host.isEmpty).font(.callout)
                    }
                }
                TextField("Port (optional)", text: $port, prompt: Text(type.defaultPort.map { "\($0)" } ?? "")).keyboardType(.numberPad)
                if type == .webdav { Toggle("Use HTTPS", isOn: $useTLS) }
            } footer: { if let note = type.formNote { Text(note) } }
            Section {
                TextField("MAC address (optional)", text: $macAddress, prompt: Text("A1:B2:C3:D4:E5:F6")).textInputAutocapitalization(.characters).autocorrectionDisabled()
            } footer: { Text("For Wake-on-LAN. If the server has gone to sleep, Reel wakes it and waits before playing. Find it in the NAS's network settings; Wake-on-LAN must be enabled there too.") }
            if type.takesCredentials {
                Section {
                    TextField("Username (optional)", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } footer: { Text("Saved to the device Keychain. Stays on this device.") }
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) } }
            Section {
                Button { Task { await test() } } label: { HStack { Spacer(); if testing { ProgressView().padding(.trailing, 6) }; Text(testing ? "Testing…" : editing == nil ? "Test Connection" : "Save"); Spacer() } }
                    .disabled(testing || host.isEmpty)
            }
        }
    }

    private var foldersStep: some View {
        Group {
            if let folderSource {
                FolderBrowser(source: folderSource, path: "", mode: .tick($picked, done: save), nav: $nav, preloaded: rootEntries)
                    .safeAreaInset(edge: .top) {
                        Banner(colour: .green, text: "Connected to \(host.isEmpty ? name : host) · \(type.displayName)") { EmptyView() }
                    }
            } else {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash", description: Text("Go back and test the connection again."))
            }
        }
    }

    // MARK: Actions

    /// Shares… lists the server's SMB shares; Browse… connects to another server's top level and
    /// walks its folders. Either fills the path field.
    private func browseForPath() async {
        testing = true; error = nil
        do {
            if type == .smb {
                shares = try await SMBSource.shares(host: host, port: Int(port), credentials: credentials)
            } else {
                var top = config; top.path = "/"
                let src = SourceFactory.make(top)
                try await src.connect(credentials: credentials)
                nav = []
                browsing = BrowseSession(source: src)
            }
        } catch { self.error = error.localizedDescription }
        testing = false
    }

    private var config: SourceConfig {
        SourceConfig(id: editing?.id ?? UUID(), name: name.isEmpty ? (host.isEmpty ? "Source" : host) : name, type: type, host: host, port: Int(port), path: path, useTLS: useTLS, username: username.isEmpty ? nil : username, macAddress: WakeOnLAN.normalise(macAddress))
    }
    private var credentials: Credentials? { username.isEmpty && password.isEmpty ? nil : Credentials(username: username, password: password) }

    private func test() async {
        testing = true; error = nil
        if !macAddress.isEmpty, WakeOnLAN.normalise(macAddress) == nil { error = WakeOnLAN.WakeError.badAddress.errorDescription; testing = false; return }
        // A blank SMB share name: offer the server's shares rather than fail.
        if type == .smb, editing == nil, path.trimmingCharacters(in: .whitespaces).isEmpty { await browseForPath(); return }
        let src = SourceFactory.make(config)
        do {
            try await src.connect(credentials: credentials)
            if let e = editing {
                e.name = config.name; e.host = host; e.port = Int(port); e.path = path; e.useTLS = useTLS; e.username = config.username; e.status = .unknown
                e.macAddress = config.macAddress; e.updatedAt = Date(); e.pendingSync = true
                if let credentials { try? CredentialStore.shared.save(credentials, for: e.id) } else { CredentialStore.shared.remove(for: e.id) }
                try? library.context.save()
                await src.disconnect()
                dismiss()
            } else {
                rootEntries = try await src.list("")
                for e in rootEntries where e.isDirectory && !DirectoryEntry.isSystemFolder(e.name) { if let t = FolderBrowser.guessTag(e.name) { picked[e.relativePath] = t } }
                folderSource = src
                step = .folders
            }
        } catch {
            self.error = error.localizedDescription
        }
        testing = false
    }

    private func loadFolders() async {
        testing = true
        let src = SourceFactory.make(config)
        do {
            try await src.connect(credentials: nil)
            rootEntries = try await src.list("")
            folderSource = src
            step = .folders
        } catch { self.error = error.localizedDescription; step = .form }
        testing = false
    }

    private func save() {
        do {
            let record = try library.addSource(config, credentials: credentials, folderRules: picked.map { ($0.key, $0.value) })
            let s = folderSource; folderSource = nil; Task { await s?.disconnect() }
            library.scan(record, providers: settings.providers)
            onComplete?()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension SourceType {
    var formHint: String {
        switch self {
        case .smb: "NAS, Mac or PC share"
        case .webdav: "Nextcloud, Synology, seedbox"
        case .ftp: "Older NAS, seedbox"
        case .sftp: "Over SSH"
        case .nfs: "Linux NAS export"
        case .dlna: "Media server"
        case .local: ""
        }
    }
    var pathLabel: String {
        switch self {
        case .webdav: "URL path"
        case .smb: "Share"
        case .ftp, .sftp: "Folder"
        case .nfs: "Export"
        case .dlna: "Description URL (optional)"
        case .local: "Folder"
        }
    }
    var pathPrompt: String {
        switch self {
        case .webdav: "/remote.php/dav/files/you"
        case .smb: "video"
        case .ftp, .sftp: "/media/video"
        case .nfs: "/volume1/video"
        case .dlna: "http://192.168.1.20:8200/rootDesc.xml"
        case .local: ""
        }
    }
    var defaultPort: Int? {
        switch self { case .ftp: 21; case .sftp: 22; case .nfs: 2049; case .smb: 445; case .webdav: nil; case .dlna: nil; case .local: nil }
    }
    var takesCredentials: Bool { self != .nfs && self != .dlna && self != .local }
    var formNote: String? {
        switch self {
        case .ftp: "Plain FTP, with passive transfers. Playback streams straight from the server; AirPlay works too."
        case .sftp: "Password sign-in over SSH, through VLC's own SFTP support, which needs a server that still offers an RSA host key with the classic ssh-rsa signature (OpenSSH 8.8 and later turn that off unless the server's config adds it back). AirPlay sends a copy of the file, so it starts after a few seconds."
        case .nfs: "The export path as the server shares it, with no sign-in (the server must allow this device's address). AirPlay sends a copy of the file, so it starts after a few seconds."
        case .dlna: "Enter the server's address. Reel asks it where its description is, or tries the usual places (MiniDLNA, Synology, Plex, Jellyfin, Emby, Serviio, Twonky). Paste the description URL if that fails. Browsing is read-only and follows the server's own folders."
        default: nil
        }
    }
}
