import SwiftUI
import MediaCore

/// The on-device log (`Diagnostics`), newest first, with share and clear. Read this first when a
/// video "just spun" or a sync went missing: it records the player's state changes, reconnects,
/// every source connection and its timing, sync results, and the app moving to and from the background.
struct DiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Text(header).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if lines.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Latest \(lines.count) entries, newest first")
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: Diagnostics.fileURL, subject: Text("Reel diagnostics"), message: Text(header)) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
            }
        }
        .confirmationDialog("Clear the diagnostics log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Diagnostics.clear(); reload() }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private var header: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let device = UIDevice.current.model
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return Diagnostics.header(appVersion: "\(version) (\(build))", device: device, system: system)
    }

    private func reload() { lines = Diagnostics.recent(limit: 500) }
}
