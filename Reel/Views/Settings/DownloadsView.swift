import SwiftUI
import MediaCore

/// Settings → Storage → Downloads: what is downloading, what is kept, and how much space it takes.
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var confirmRemoveAll = false

    var body: some View {
        let finished = downloads.finished()
        List {
            if !downloads.active.isEmpty {
                Section("In progress") {
                    ForEach(downloads.active) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.title).font(.subheadline.weight(.semibold))
                            if let s = e.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                            switch e.state {
                            case .queued: Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                            case .downloading:
                                ProgressView(value: e.progress)
                                Text("\(MediaFormat.bytes(e.bytes)) of \(MediaFormat.bytes(e.total))").font(.caption).foregroundStyle(.secondary)
                            case .failed(let why):
                                Text(why).font(.caption).foregroundStyle(.red)
                                Button("Retry") { downloads.retry(e.itemKey) }.font(.caption)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { downloads.cancel(e.itemKey) } label: { Label("Cancel", systemImage: "xmark") } }
                    }
                }
            }
            Section {
                if finished.isEmpty {
                    Text("Nothing downloaded. Use Download in an episode's or film's menu to keep a copy on this device.").foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(finished, id: \.itemKey) { f in
                    HStack {
                        Text(f.title).lineLimit(2)
                        Spacer()
                        Text(MediaFormat.bytes(f.bytes)).foregroundStyle(.secondary).font(.caption)
                    }
                    .swipeActions { Button(role: .destructive) { downloads.remove(f.itemKey) } label: { Label("Remove", systemImage: "trash") } }
                }
            } header: {
                Text("On this device · \(MediaFormat.bytes(downloads.totalBytes))")
            } footer: {
                Text("Downloads play even when the NAS is unreachable, and are never backed up to iCloud.")
            }
            if !finished.isEmpty {
                Section { Button("Remove all downloads", role: .destructive) { confirmRemoveAll = true } }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Remove every download from this device?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
        }
        .onAppear { downloads.refresh() }
    }
}
