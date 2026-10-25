#if canImport(VLCKit)
import Foundation
import VLCKit
import MediaCore

/// Turns an MKV into an MP4 Apple's player can stream over AirPlay, without re-encoding: VLC's
/// stream output copies the video and audio into an MP4 in Caches, then the HEVC sample entry is
/// relabelled hev1 → hvc1 (Apple only accepts hvc1, and VLC writes the parameter sets in the hvcC
/// box either way, so the label is the only difference). The copy takes about as long as reading the
/// file from the share; the caller shows progress. Copies are kept per file so the second AirPlay of
/// an episode is instant, and swept with the other caches.
@MainActor
public final class AirPlayRemuxer: NSObject, VLCMediaPlayerDelegate {
    public static let shared = AirPlayRemuxer()

    public static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("airplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var player: VLCMediaPlayer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var progressHandler: ((Double) -> Void)?
    private var duration: TimeInterval = 0
    private var output: URL?
    private var started = Date()

    public enum RemuxError: LocalizedError {
        case alreadyRunning, failed(String), empty
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Another AirPlay copy is still being made."
            case .failed(let m): "Couldn't prepare this file for AirPlay: \(m)"
            case .empty: "Couldn't prepare this file for AirPlay: nothing was written."
            }
        }
    }

    /// The finished MP4 for `key` if one exists already.
    public static func existing(for key: String) -> URL? {
        let url = directory.appendingPathComponent(fileName(key))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private static func fileName(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16) + ".mp4"
    }

    /// Copies `source` into an AirPlay-ready MP4. `duration` (seconds) drives the progress figure.
    public func remux(source: URL, key: String, duration: TimeInterval, progress: @escaping (Double) -> Void) async throws -> URL {
        if let done = Self.existing(for: key) { return done }
        guard player == nil else { throw RemuxError.alreadyRunning }
        let final = Self.directory.appendingPathComponent(Self.fileName(key))
        let temp = Self.directory.appendingPathComponent(Self.fileName(key) + ".part")
        try? FileManager.default.removeItem(at: temp)
        guard let media = VLCMedia(url: source) else { throw RemuxError.failed("VLC couldn't open the file") }
        media.addOption(":sout=#std{access=file,mux=mp4,dst=\(temp.path)}")
        // No sout-keep: it keeps the stream output (and so the muxer, and the unwritten index) alive
        // past this player's stop, and the MP4 never gets its moov.
        media.addOption(":no-sout-keep")
        media.addOption(":no-sout-display")
        media.addOption(":no-sout-video-sync")   // copy as fast as the share delivers, not at playback speed
        media.addOption(":network-caching=3000")
        let p = VLCMediaPlayer()
        p.delegate = self
        player = p
        p.media = media
        self.duration = duration
        output = temp
        progressHandler = progress
        started = Date()
        Diagnostics.log("airplay", "remux start: \(Diagnostics.safe(source))")
        p.play()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in continuation = cont }
        } catch {
            cleanup()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        cleanup()
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw RemuxError.empty }
        // The muxer finishes the file (moov, then the mdat size) a little after VLC reports stopped;
        // the index is only findable once both are in. Try for up to twenty seconds.
        var indexed = false
        for _ in 0..<40 {
            if try Self.relabelHEVC(at: temp) { indexed = true; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard indexed else { throw RemuxError.failed("the copy has no index; the file may be incomplete") }
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: temp, to: final)
        Diagnostics.log("airplay", "remux done: \(size / 1_000_000) MB in \(Int(Date().timeIntervalSince(started)))s")
        return final
    }

    /// Stops a copy in progress (the user backed out).
    public func cancel() {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(throwing: CancellationError())
    }

    private func cleanup() {
        player?.stop()
        let old = player
        player = nil
        progressHandler = nil
        // Releasing the player closes its stream output, which is when the muxer writes the index.
        Task.detached(priority: .userInitiated) { [old] in _ = old }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            guard let p = self.player, self.duration > 0 else { return }
            self.progressHandler?(min(0.99, TimeInterval(p.time.intValue) / 1000 / self.duration))
        }
    }

    nonisolated public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            switch newState {
            case .stopped:
                // The copy ran to the end (VLC stops on its own), but the muxer writes the index (moov) and
                // the mdat size on close, a moment after the state change: wait until the file stops growing.
                guard let c = self.continuation else { return }
                self.continuation = nil
                c.resume()
            case .error:
                guard let c = self.continuation else { return }
                self.continuation = nil
                c.resume(throwing: RemuxError.failed("VLC reported an error"))
            default: break
            }
        }
    }

    /// Finds the `moov` box (top level, usually last) and rewrites any `hev1` sample entry as `hvc1`.
    /// Returns false when there is no `moov` yet (the muxer has not closed the file).
    @discardableResult
    static func relabelHEVC(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let head = try handle.read(upToCount: 16), head.count >= 8 else { break }
            var size = UInt64(UInt32(bigEndian: head[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
            let type = String(decoding: head[4..<8], as: UTF8.self)
            if size == 1, head.count >= 16 { size = UInt64(bigEndian: head[8..<16].withUnsafeBytes { $0.load(as: UInt64.self) }) }
            if size == 0 { size = fileSize - offset }
            if type == "moov", size < 64 * 1024 * 1024 {
                try handle.seek(toOffset: offset)
                guard var moov = try handle.read(upToCount: Int(size)) else { break }
                var patched = 0
                var search = moov.startIndex
                while let r = moov.range(of: Data("hev1".utf8), in: search..<moov.endIndex) {
                    moov.replaceSubrange(r, with: Data("hvc1".utf8)); patched += 1; search = r.upperBound
                }
                if patched > 0 {
                    try handle.seek(toOffset: offset)
                    try handle.write(contentsOf: moov)
                    Diagnostics.log("airplay", "relabelled \(patched) HEVC sample entries hev1 → hvc1")
                }
                return true
            }
            if size < 8 { return false }
            offset += size
        }
        return false
    }

    /// Drops copies older than a week, or all of them.
    public static func sweep(all: Bool = false) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if all || Date().timeIntervalSince(modified) > 7 * 24 * 3600 || f.pathExtension == "part" { try? FileManager.default.removeItem(at: f) }
        }
    }
}
#endif
