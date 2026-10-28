import SwiftUI
import Sync

/// Shown instead of the library while a restore from iCloud runs, so titles never appear before
/// their files have arrived and been linked. Counts tick up as records land; the bar appears once
/// the other device's totals are in. "Continue in the background" shows the library as it fills.
struct RestoreView: View {
    let progress: RestoreProgress
    @EnvironmentObject private var sync: SyncEngine

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Restoring your library").font(.title2.weight(.bold))
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(maxWidth: 320)
                Text("\(Int(fraction * 100))%").font(.headline).monospacedDigit()
            } else {
                ProgressView()
                Text("Working out how much there is…").font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                row("Libraries", progress.sources, of: nil)
                row("Titles", progress.items, of: progress.expectedItems)
                row("Files", progress.files, of: progress.expectedFiles)
            }
            .font(.callout).monospacedDigit()
            TimelineView(.periodic(from: progress.startedAt, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(progress.startedAt))
                Text("\(s / 60)m \(s % 60)s").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            if let error = sync.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            Spacer()
            Button("Continue in the background") { sync.dismissRestore() }.font(.footnote)
            Text("Titles may appear before their files arrive; they become playable as the restore finishes.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadialGradient(colors: [Color.accentColor.opacity(0.25), Color(.systemBackground)], center: .top, startRadius: 0, endRadius: 500).ignoresSafeArea())
    }

    private func row(_ label: String, _ n: Int, of total: Int?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(total.map { "\(n.formatted()) of \($0.formatted())" } ?? n.formatted())
        }
        .frame(maxWidth: 320)
    }
}
