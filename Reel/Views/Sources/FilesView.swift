import SwiftUI
import MediaCore
import Library

/// Files: the plain view of everything Reel can reach, as a list. The downloads on this device
/// first, then each source as a folder tree, every video and audio file playable whether or not
/// the library matched it. For what the library did match, the posters are in Home, TV and Films.
struct FilesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var refresh = 0

    var body: some View {
        let sources = library.sources()
        let books = library.audiobooks()
        List {
            Section {
                NavigationLink { DownloadsView() } label: {
                    row("Downloads", systemImage: "arrow.down.circle", detail: downloadsDetail)
                }
                if !books.isEmpty {
                    NavigationLink { AudiobooksView() } label: {
                        row("Audiobooks", systemImage: "headphones", detail: "\(books.count) \(books.count == 1 ? "book" : "books")")
                    }
                }
            } header: { Text("On this device") }
            Section {
                if sources.isEmpty {
                    NavigationLink { SourcesView() } label: {
                        row("Add a source", systemImage: "plus.circle", detail: "A NAS, a share or a media server to browse")
                    }
                }
                ForEach(sources, id: \.id) { s in
                    NavigationLink { FileBrowserView(source: s, path: "") } label: {
                        row(s.name, systemImage: s.status == .offline ? "externaldrive.badge.xmark" : "externaldrive.connected.to.line.below", detail: detail(s))
                    }
                }
            } header: { Text("Sources") } footer: {
                Text("Every folder as it is on the server. Videos and audio play straight from here, in the library or not.")
            }
        }
        .navigationTitle("Files")
        .itemNavigation()
        .onReceive(library.objectWillChange) { _ in refresh += 1 }
    }

    private var downloadsDetail: String {
        let finished = downloads.finished()
        let bytes = finished.reduce(Int64(0)) { $0 + $1.bytes }
        var parts = ["\(finished.count) \(finished.count == 1 ? "file" : "files")"]
        if bytes > 0 { parts.append(MediaFormat.bytes(bytes)) }
        if !downloads.active.isEmpty { parts.append("\(downloads.active.count) downloading") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ s: SourceRecord) -> String {
        var parts = [s.type.displayName]
        if !s.host.isEmpty { parts.append(s.host) }
        if !s.path.isEmpty { parts.append(s.path) }
        if s.status == .offline { parts.append("offline") }
        return parts.joined(separator: " · ")
    }

    private func row(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
