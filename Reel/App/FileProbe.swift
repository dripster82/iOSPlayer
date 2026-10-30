import Foundation
import MediaCore
import Library
import Playback

/// Fills in what a scan never reads: length, codecs, size and subtitle count for files nobody has
/// played yet, so a film page's File section is right from the start. A handful of files after
/// each scan and at launch, one at a time, each a few seconds over the share; it stands down in
/// Low Power Mode or when the device is hot, and when a file will not open it is left for the player.
@MainActor
enum FileProbe {
    private static var running = false
    /// Files the probe could not open; not retried this launch.
    private static var failed = Set<UUID>()

    static func probePending(library: LibraryStore, limit: Int = 25) {
        guard !running else { return }
        let pending = library.filesNeedingProbe(limit: limit + failed.count).filter { !failed.contains($0.id) }.prefix(limit)
        guard !pending.isEmpty else { return }
        running = true
        Diagnostics.log("library", "probing \(pending.count) files for length and codecs")
        Task {
            defer { running = false }
            var done = 0
            for file in pending {
                guard DeviceConditions.allowsBackgroundWork, !file.isDeleted else { break }
                guard let (url, _) = try? await library.playbackURL(for: file), let r = await MediaProbe.probe(url) else { failed.insert(file.id); continue }
                library.recordProbe(file, videoCodec: r.videoCodec, audio: r.audio, subtitles: r.subtitles, duration: r.duration, resolution: r.resolution)
                done += 1
            }
            Diagnostics.log("library", "probed \(done) of \(pending.count) files")
        }
    }
}
