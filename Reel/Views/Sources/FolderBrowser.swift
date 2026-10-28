import SwiftUI
import MediaCore
import MediaSources

/// A folder on a source as a navigation destination.
struct BrowseFolder: Hashable { let path: String }

/// One folder of a connected source, with a way into each sub-folder. Two jobs: choosing a single
/// folder as the source's path (the add form), or ticking library folders, with a tag each, at any
/// depth (the folders step). Each level lists itself when it appears.
struct FolderBrowser: View {
    enum Mode {
        case chooseOne((String) -> Void)
        case tick(Binding<[String: FolderTag]>, done: () -> Void)
    }
    let source: any MediaSource
    let path: String
    let mode: Mode
    @Binding var nav: [BrowseFolder]
    var preloaded: [DirectoryEntry]? = nil
    @State private var entries: [DirectoryEntry]?
    @State private var error: String?

    private var name: String { (path as NSString).lastPathComponent }
    private var folders: [DirectoryEntry] { (entries ?? []).filter { $0.isDirectory && !DirectoryEntry.isSystemFolder($0.name) } }

    var body: some View {
        List {
            if case .chooseOne(let choose) = mode {
                Section {
                    Button { choose(path) } label: { Label(path.isEmpty ? "Use the top level" : "Use “\(name)”", systemImage: "checkmark.circle") }
                } footer: { Text(path.isEmpty ? "Or open a folder below to use one inside it." : "Or go further into a folder below.") }
            }
            Section {
                if entries != nil, folders.isEmpty {
                    Text(path.isEmpty ? "No sub-folders. The whole share will be scanned." : "No sub-folders.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.relativePath) { e in row(e) }
            } header: {
                if case .tick = mode { Text(path.isEmpty ? "Tick the folders to scan and say what's in each" : "Inside \(name)") }
            } footer: {
                if case .tick = mode, path.isEmpty { Text("Open a folder to tick something inside it. Untagged folders are classified from file names. You can change tags later from the source page.") }
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) } }
        }
        .overlay { if entries == nil && error == nil { ProgressView() } }
        .navigationTitle(path.isEmpty ? (isTick ? "Folders" : "Choose a folder") : name)
        .toolbar {
            if case .tick(let picked, let done) = mode {
                ToolbarItem(placement: .confirmationAction) { Button("Start scanning") { done() }.disabled(picked.wrappedValue.isEmpty && !path.isEmpty) }
            }
        }
        .task { await load() }
    }

    private var isTick: Bool { if case .tick = mode { return true }; return false }

    @ViewBuilder private func row(_ e: DirectoryEntry) -> some View {
        switch mode {
        case .chooseOne:
            Button { nav.append(BrowseFolder(path: e.relativePath)) } label: {
                HStack { Label(e.name, systemImage: "folder").foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
            }
        case .tick(let picked, _):
            let on = picked.wrappedValue[e.relativePath] != nil
            HStack {
                Button { toggle(e, in: picked) } label: { Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary) }.buttonStyle(.plain)
                Button { nav.append(BrowseFolder(path: e.relativePath)) } label: {
                    HStack { Text(e.name).foregroundStyle(.primary).lineLimit(1); Spacer(minLength: 4) }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if on {
                    Picker("", selection: Binding(get: { picked.wrappedValue[e.relativePath] ?? .mixed }, set: { picked.wrappedValue[e.relativePath] = $0 })) {
                        Text("TV").tag(FolderTag.tv); Text("Films").tag(FolderTag.films); Text("Mixed").tag(FolderTag.mixed)
                    }.pickerStyle(.segmented).frame(width: 170)
                }
                Button { nav.append(BrowseFolder(path: e.relativePath)) } label: { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary).padding(.leading, 4) }.buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ e: DirectoryEntry, in picked: Binding<[String: FolderTag]>) {
        if picked.wrappedValue[e.relativePath] != nil { picked.wrappedValue[e.relativePath] = nil }
        else { picked.wrappedValue[e.relativePath] = Self.guessTag(e.name) ?? .mixed }
    }

    static func guessTag(_ name: String) -> FolderTag? {
        let n = name.lowercased()
        if ["tv", "tv shows", "shows", "series"].contains(n) { return .tv }
        if ["films", "movies", "film", "movie", "cinema"].contains(n) { return .films }
        return nil
    }

    private func load() async {
        if entries != nil { return }
        if let preloaded { entries = preloaded; return }
        do { entries = try await source.list(path) } catch { self.error = error.localizedDescription }
    }
}
