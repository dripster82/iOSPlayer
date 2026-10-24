import SwiftUI
import UniformTypeIdentifiers
import MediaCore
import MediaSources
import Library

/// Type → (discovered | manual form) → Test Connection → folders → scan. Also used to edit credentials.
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
    @State private var testing = false
    @State private var error: String?
    @State private var rootEntries: [DirectoryEntry] = []
    @State private var picked: [String: FolderTag] = [:]
    @State private var showPicker = false
    @State private var localBookmark: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .type: typeStep
                case .form: formStep
                case .folders: foldersStep
                }
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
                step = .form
            } else { discovery.start() }
        }
        .onDisappear { discovery.stop() }
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
                if discovery.hosts.isEmpty { HStack { ProgressView(); Text("Looking for SMB and WebDAV hosts…").font(.footnote).foregroundStyle(.secondary) } }
                ForEach(discovery.hosts) { h in
                    Button { type = h.type; name = h.name; host = h.host; step = .form } label: {
                        HStack { Circle().fill(.green).frame(width: 9, height: 9); VStack(alignment: .leading) { Text(h.name).foregroundStyle(.primary); Text(h.host).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(h.type.displayName).font(.caption2.bold()).foregroundStyle(.secondary) }
                    }
                }
            } header: { Text("Found on your network") }
            Section("Or enter manually") {
                ForEach([SourceType.smb, .webdav, .ftp, .sftp, .nfs, .dlna]) { t in
                    Button { type = t; step = .form } label: { HStack { Text(t.displayName).foregroundStyle(.primary); Spacer(); if t.isComingSoon { Text("Soon").font(.caption2).foregroundStyle(.secondary) } } }
                        .disabled(t.isComingSoon)
                }
            }
        }
    }

    private var formStep: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Living room NAS"))
                TextField("Host or IP", text: $host, prompt: Text("192.168.1.20 or nas.local")).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField(type == .webdav ? "URL path" : "Share", text: $path, prompt: Text(type == .webdav ? "/remote.php/dav/files/you" : "video")).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port (optional)", text: $port).keyboardType(.numberPad)
                if type == .webdav { Toggle("Use HTTPS", isOn: $useTLS) }
            }
            Section {
                TextField("Username (optional)", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
            } footer: { Text("Saved to the device Keychain. Stays on this device.") }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) } }
            Section {
                Button { Task { await test() } } label: { HStack { Spacer(); if testing { ProgressView().padding(.trailing, 6) }; Text(testing ? "Testing…" : editing == nil ? "Test Connection" : "Save"); Spacer() } }
                    .disabled(testing || host.isEmpty)
            }
        }
    }

    private var foldersStep: some View {
        List {
            Section {
                Banner(colour: .green, text: "Connected to \(host.isEmpty ? name : host) · \(type.displayName)") { EmptyView() }
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section {
                ForEach(rootEntries.filter(\.isDirectory), id: \.relativePath) { e in
                    HStack {
                        Button { toggle(e.relativePath) } label: { Image(systemName: picked[e.relativePath] != nil ? "checkmark.square.fill" : "square").foregroundStyle(picked[e.relativePath] != nil ? Color.accentColor : .secondary) }.buttonStyle(.plain)
                        Text(e.name)
                        Spacer()
                        if picked[e.relativePath] != nil {
                            Picker("", selection: Binding(get: { picked[e.relativePath] ?? .mixed }, set: { picked[e.relativePath] = $0 })) {
                                Text("TV").tag(FolderTag.tv); Text("Films").tag(FolderTag.films); Text("Mixed").tag(FolderTag.mixed)
                            }.pickerStyle(.segmented).frame(width: 190)
                        }
                    }
                }
                if rootEntries.filter(\.isDirectory).isEmpty {
                    Text("No sub-folders. The whole share will be scanned.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Tick the folders to scan and say what's in each") } footer: { Text("Untagged folders are classified from file names. You can change tags later from the source page.") }
            Section {
                Button { save() } label: { HStack { Spacer(); Text("Start scanning"); Spacer() } }
            }
        }
    }

    // MARK: Actions

    private func guessTag(_ name: String) -> FolderTag? {
        let n = name.lowercased()
        if ["tv", "tv shows", "shows", "series"].contains(n) { return .tv }
        if ["films", "movies", "film", "movie", "cinema"].contains(n) { return .films }
        return nil
    }

    private func toggle(_ p: String) {
        if picked[p] != nil { picked[p] = nil } else { picked[p] = guessTag((p as NSString).lastPathComponent) ?? .mixed }
    }

    private var config: SourceConfig {
        SourceConfig(id: editing?.id ?? UUID(), name: name.isEmpty ? (host.isEmpty ? "Source" : host) : name, type: type, host: host, port: Int(port), path: path, useTLS: useTLS, username: username.isEmpty ? nil : username)
    }
    private var credentials: Credentials? { username.isEmpty && password.isEmpty ? nil : Credentials(username: username, password: password) }

    private func test() async {
        testing = true; error = nil
        let src = SourceFactory.make(config)
        do {
            try await src.connect(credentials: credentials)
            if let e = editing {
                e.name = config.name; e.host = host; e.port = Int(port); e.path = path; e.useTLS = useTLS; e.username = config.username; e.status = .unknown
                if let credentials { try? CredentialStore.shared.save(credentials, for: e.id) } else { CredentialStore.shared.remove(for: e.id) }
                try? library.context.save()
                await src.disconnect()
                dismiss()
            } else {
                rootEntries = try await src.list("")
                await src.disconnect()
                for e in rootEntries where e.isDirectory { if let t = guessTag(e.name) { picked[e.relativePath] = t } }
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
            await src.disconnect()
            step = .folders
        } catch { self.error = error.localizedDescription; step = .form }
        testing = false
    }

    private func save() {
        do {
            let record = try library.addSource(config, credentials: credentials, folderRules: picked.map { ($0.key, $0.value) })
            library.scan(record, providers: settings.providers)
            onComplete?()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension SourceType {
    /// Browse support for these lands after v1 (PLAN.md §11.3). VLC can still play their URLs.
    var isComingSoon: Bool { [.ftp, .sftp, .nfs, .dlna].contains(self) }
}
