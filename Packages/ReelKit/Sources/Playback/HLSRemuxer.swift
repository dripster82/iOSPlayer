#if canImport(VLCKit)
import Foundation
import VLCKit
import MediaCore

/// Turns an MKV into an HLS stream Apple's player can play over AirPlay, starting within seconds.
///
/// VLC's stream output copies the video and audio (no re-encoding) into a fragmented MP4. It is
/// written to a named pipe, which is not seekable, so the muxer puts the index first and emits
/// moof/mdat fragments as it goes. A reader on the other end of the pipe cuts that into an init
/// segment (ftyp + moov, with HEVC relabelled hev1 → hvc1, the one thing Apple insists on) and one
/// segment per fragment, and keeps an EVENT playlist up to date. Playback starts once two segments
/// exist; the rest of the file arrives behind the playhead at share speed. When the copy finishes
/// the playlist gets ENDLIST and is kept for a week, so the next AirPlay of that title is instant.
@MainActor
public final class HLSRemuxer: NSObject, VLCMediaPlayerDelegate {
    public static let shared = HLSRemuxer()

    public static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("airplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public enum RemuxError: LocalizedError {
        case alreadyRunning, failed(String), notFragmented, timeout
        /// The copy met codecs Apple's player refuses; the plan says what to convert.
        case needsConversion(HLSRemuxer.Plan)
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Another AirPlay stream is still being prepared."
            case .failed(let m): m.hasPrefix("AirPlay can carry") ? m : "Couldn't prepare this file for AirPlay: \(m)"
            case .notFragmented: "Couldn't prepare this file for AirPlay: the copy was not streamable."
            case .timeout: "Couldn't prepare this file for AirPlay: nothing arrived from the file in time."
            case .needsConversion: "This file needs converting for AirPlay."
            }
        }
    }

    private var player: VLCMediaPlayer?
    private var segmenter: Segmenter?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    fileprivate(set) var currentDirectory: URL?
    /// What the segmenter reported before anyone was waiting for it (it can fail within a frame).
    private var outcome: Result<Void, Error>?

    /// A finished stream for `key`, if there is one.
    public static func completed(for key: String) -> URL? {
        let dir = directory.appendingPathComponent(folderName(key), isDirectory: true)
        let playlist = dir.appendingPathComponent("video.m3u8")
        guard let text = try? String(contentsOf: playlist, encoding: .utf8), text.contains("#EXT-X-ENDLIST") else { return nil }
        return dir
    }
    private static func folderName(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Starts the stream for `source` and returns its folder (with index.m3u8) as soon as it can be
    /// played. `startAt` begins the copy near that time; the stream's own clock then starts at zero,
    /// so the caller adds it back when saving progress. A stream started part-way is not kept.
    /// A subtitle file to offer alongside the stream: its display name and SRT/VTT text.
    public struct SubtitleFile: Sendable { public var name: String; public var language: String; public var data: Data
        public init(name: String, language: String, data: Data) { self.name = name; self.language = language; self.data = data } }

    /// The playlist to hand to the player.
    public static func playlistName(in directory: URL) -> String { "master.m3u8" }

    /// Every audio track is copied and offered as an HLS audio rendition, so Apple's player has its
    /// own audio menu; `preferredAudio` (an index among the audio tracks, VLC's order) or
    /// `preferredLanguage` picks the one marked DEFAULT.
    /// `status` is told what the copy is doing when it is more than a copy ("Converting XviD video…").
    public func start(source: URL, key: String, startAt: TimeInterval, subtitles: [SubtitleFile] = [], preferredAudio: Int? = nil, preferredLanguage: String? = nil, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        if startAt <= 0, let done = Self.completed(for: key) {
            let subs = Segmenter.writeSubtitleFiles(subtitles, in: done, offset: 0, duration: Self.duration(of: done))
            Segmenter.writeMaster(in: done, tracks: Segmenter.tracksFromInits(in: done), subtitleLines: subs, preferredAudio: preferredAudio, preferredLanguage: preferredLanguage)
            return done
        }
        guard player == nil else { throw RemuxError.alreadyRunning }
        // What is in the file decides between a plain copy and a conversion: Apple's player takes only
        // H.264/HEVC video and AAC-family audio, and the iPad's hardware encoder makes H.264 faster
        // than real time, so XviD, VP9, AV1, MPEG-2 and the rest are converted as they stream. The
        // probe can come up empty (a slow share, a container VLC's preparser skips); then the copy
        // is tried, and if the segmenter meets codecs the player would refuse, the stream restarts
        // as a conversion with what the segmenter saw.
        let plan = await Self.plan(for: source)
        do {
            return try await attempt(source: source, key: key, startAt: startAt, subtitles: subtitles, preferredAudio: preferredAudio, preferredLanguage: preferredLanguage, plan: plan, status: status)
        } catch RemuxError.needsConversion(let found) where plan.chain.isEmpty {
            Diagnostics.log("airplay", "copy refused; converting instead")
            return try await attempt(source: source, key: key, startAt: startAt, subtitles: subtitles, preferredAudio: preferredAudio, preferredLanguage: preferredLanguage, plan: found, status: status)
        } catch RemuxError.needsConversion(let found) {
            throw RemuxError.failed("the conversion still produced \(found.video.map { MP4Boxes.describe(codec: $0) } ?? found.audio.map { MP4Boxes.describe(codec: $0) }.joined(separator: ", ")), which AirPlay cannot carry")
        }
    }

    private func attempt(source: URL, key: String, startAt: TimeInterval, subtitles: [SubtitleFile], preferredAudio: Int?, preferredLanguage: String?, plan: Plan, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        let dir = Self.directory.appendingPathComponent(Self.folderName(key) + (startAt > 0 ? "-partial" : ""), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pipe = dir.appendingPathComponent("pipe")
        guard mkfifo(pipe.path, 0o600) == 0 else { throw RemuxError.failed("couldn't make a pipe") }
        currentDirectory = dir
        outcome = nil

        guard let media = VLCMedia(url: source) else { throw RemuxError.failed("VLC couldn't open the file") }
        if let note = plan.description { status(note); Diagnostics.log("airplay", note) }
        // mp4frag is VLC 4's fragmented, streamable MP4 muxer: index first, then moof/mdat fragments.
        media.addOption(":sout=#\(plan.chain)std{access=file,mux=mp4frag,dst=\(pipe.path)}")
        media.addOption(":no-sout-keep")
        media.addOption(":no-sout-display")
        media.addOption(":sout-mux-caching=300")
        media.addOption(":network-caching=3000")
        if startAt > 0 { media.addOption(":start-time=\(Int(startAt))") }
        media.addOption(":sout-all")   // every audio track, not just the one VLC would play
        let p = VLCMediaPlayer()
        p.delegate = self
        player = p
        p.media = media

        let seg = Segmenter(directory: dir, pipe: pipe, subtitles: subtitles, subtitleOffset: startAt, preferredAudio: preferredAudio, preferredLanguage: preferredLanguage) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        segmenter = seg
        seg.start()
        Diagnostics.log("airplay", "stream start at \(Int(startAt))s: \(Diagnostics.safe(source))")
        p.play()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        if let outcome = self.outcome { cont.resume(with: outcome) } else { self.readyContinuation = cont }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(90))
                    throw RemuxError.timeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            stop(discard: true)
            throw error
        }
        return dir
    }

    /// What the stream output must do to a file: copy its tracks, or convert the ones Apple's
    /// player would refuse.
    public struct Plan: Sendable {
        var video: String?      // the source video codec when it needs converting
        var audio: [String] = []   // the source audio codecs when they need converting
        var width = 0, height = 0
        init(video: String? = nil, audio: [String] = [], width: Int = 0, height: Int = 0) { self.video = video; self.audio = audio; self.width = width; self.height = height }
        var chain: String {
            var parts: [String] = []
            if video != nil {
                // Bit rate by picture size; the VideoToolbox encoder in real-time mode keeps up with playback.
                let kbps = height <= 480 ? 2500 : height <= 720 ? 5000 : height <= 1080 ? 8000 : 14000
                parts.append("vcodec=h264,venc=avcodec{codec=h264_videotoolbox,options{realtime=1}},vb=\(kbps)")
            }
            if !audio.isEmpty { parts.append("acodec=mp4a,ab=192,channels=2,samplerate=48000") }
            return parts.isEmpty ? "" : "transcode{\(parts.joined(separator: ","))}:"
        }
        var description: String? {
            var bits: [String] = []
            if let video { bits.append("\(MP4Boxes.describe(codec: video)) video to H.264") }
            if !audio.isEmpty { bits.append("\(Set(audio).map { MP4Boxes.describe(codec: $0) }.sorted().joined(separator: "/")) audio to AAC") }
            return bits.isEmpty ? nil : "Converting " + bits.joined(separator: " and ") + " for AirPlay…"
        }
    }

    /// Reads the file's track codecs (a parse, no playback) and decides what to convert. A file that
    /// cannot be read in time is copied as is; the segmenter still checks what arrives.
    /// Debug builds: skip the probe to exercise the copy-then-convert fallback.
    public static var debugSkipProbe = false

    @MainActor
    static func plan(for source: URL) async -> Plan {
        var plan = Plan()
        if debugSkipProbe { Diagnostics.log("airplay", "probe skipped (debug)"); return plan }
        guard let media = VLCMedia(url: source) else { return plan }
        media.addOption(":network-caching=1500")
        let watcher = ParseWatcher()
        media.delegate = watcher
        let started = Date()
        let rc = media.parse(options: [.parseNetwork], timeout: 15000)
        guard rc == 0 else { Diagnostics.log("airplay", "probe: parse refused (\(rc))"); return plan }
        await watcher.wait(seconds: 16)
        media.delegate = nil
        let codecs = (media.videoTracks + media.audioTracks).map { Self.fourcc($0.codec) }
        Diagnostics.log("airplay", "probe: status \(media.parsedStatus.rawValue) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s, tracks \(codecs)")
        guard media.parsedStatus == .done else { return plan }
        if let v = media.videoTracks.first {
            let fourcc = Self.fourcc(v.codec)
            if !["h264", "avc1", "hevc", "hvc1", "hev1"].contains(fourcc) { plan.video = fourcc }
            plan.width = Int(v.video?.width ?? 0); plan.height = Int(v.video?.height ?? 0)
        }
        let supported: Set<String> = ["mp4a", "aac ", "a52 ", "ac-3", "eac3", "ec-3", "alac", "flac", "fLaC"]
        let audio = media.audioTracks.map { Self.fourcc($0.codec) }
        if audio.contains(where: { !supported.contains($0) }) { plan.audio = audio.filter { !supported.contains($0) } }
        return plan
    }

    private static func fourcc(_ code: UInt32) -> String {
        let bytes = [UInt8(code & 0xFF), UInt8((code >> 8) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 24) & 0xFF)]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private final class ParseWatcher: NSObject, VLCMediaDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false
        func wait(seconds: Double) async {
            if finished { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                continuation = c
                Task { try? await Task.sleep(for: .seconds(seconds)); self.finish() }
            }
        }
        private func finish() { finished = true; continuation?.resume(); continuation = nil }
        func mediaDidFinishParsing(_ aMedia: VLCMedia) { finish() }
    }

    /// Stops the copy (the user backed out). A stream that was not finished is discarded.
    public func cancel() { stop(discard: !(segmenter?.finished ?? false)) }

    private func stop(discard: Bool) {
        if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: CancellationError()) }
        let old = player
        player = nil
        let seg = segmenter
        segmenter = nil
        let dir = discard ? currentDirectory : nil
        currentDirectory = nil
        // VLC's stop can wait on a writer blocked on the pipe, and a folder of thousands of segments
        // takes a moment to delete: neither belongs on the main thread. The reader keeps draining the
        // pipe until VLC closes it, so that writer is never stuck.
        Task.detached(priority: .userInitiated) { [old, seg, dir] in
            seg?.cancel()
            old?.stop()
            _ = old
            if let dir {
                try? await Task.sleep(for: .seconds(1))
                // A retry (copy → conversion) may have taken the same folder meanwhile: leave it alone then.
                let reused = await MainActor.run { HLSRemuxer.shared.currentDirectory == dir }
                if !reused { try? FileManager.default.removeItem(at: dir) }
            }
        }
    }

    private func handle(_ event: Segmenter.Event) {
        switch event {
        case .ready:
            outcome = .success(())
            if let c = readyContinuation { readyContinuation = nil; c.resume() }
        case .finished(let segments, let seconds):
            Diagnostics.log("airplay", "stream complete: \(segments) segments, \(Int(seconds))s")
            // VLC has closed the pipe; let the player go.
            player?.stop()
            let old = player; player = nil
            Task.detached(priority: .userInitiated) { [old] in _ = old }
        case .failed(let message):
            Diagnostics.log("airplay", "stream failed: \(message)")
            outcome = .failure(RemuxError.failed(message))
            if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: RemuxError.failed(message)) }
            stop(discard: true)
        case .unsupported(let plan):
            Diagnostics.log("airplay", "copy has codecs AirPlay refuses: video \(plan.video ?? "ok"), audio \(plan.audio)")
            outcome = .failure(RemuxError.needsConversion(plan))
            if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: RemuxError.needsConversion(plan)) }
            stop(discard: true)
        }
    }

    nonisolated public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            if newState == .error, let c = self.readyContinuation {
                self.readyContinuation = nil
                c.resume(throwing: RemuxError.failed("VLC reported an error"))
                self.stop(discard: true)
            }
        }
    }

    private static func duration(of dir: URL) -> TimeInterval {
        let text = (try? String(contentsOf: dir.appendingPathComponent("video.m3u8"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { l -> Double? in l.hasPrefix("#EXTINF:") ? Double(l.dropFirst(8).split(separator: ",").first ?? "") : nil }.reduce(0, +)
    }

    /// Drops streams older than a week, and every partial one.
    public static func sweep(all: Bool = false) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for d in dirs {
            let modified = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let partial = d.lastPathComponent.hasSuffix("-partial") || completedPlaylist(in: d) == false
            if all || partial || Date().timeIntervalSince(modified) > 7 * 24 * 3600 { try? FileManager.default.removeItem(at: d) }
        }
    }
    private static func completedPlaylist(in dir: URL) -> Bool {
        (try? String(contentsOf: dir.appendingPathComponent("video.m3u8"), encoding: .utf8))?.contains("#EXT-X-ENDLIST") ?? false
    }
}

// MARK: - Segmenter

/// Reads the fragmented MP4 from the pipe on its own thread and writes one HLS rendition per
/// track: init-<track>.mp4, <track>-<n>.m4s and video.m3u8 / audio-<track>.m3u8, plus master.m3u8,
/// which lists the video with every audio track as an alternate rendition (Apple's player then
/// offers them in its own audio menu and switches without a restart) and the subtitle files.
final class Segmenter: @unchecked Sendable {
    enum Event { case ready, finished(segments: Int, seconds: Double), failed(String), unsupported(HLSRemuxer.Plan) }

    private let directory: URL
    private let pipe: URL
    private let subtitles: [HLSRemuxer.SubtitleFile]
    private let subtitleOffset: TimeInterval
    private let preferredAudio: Int?
    private let preferredLanguage: String?
    private let onEvent: (Event) -> Void
    private var fd: Int32 = -1
    private var cancelled = false
    private(set) var finished = false
    private var thread: Thread?

    private var tracks: [MP4Boxes.Track] = []
    /// Default sample sizes for every track in the file, dropped audio included: the shared mdat is
    /// laid out by all of them, so a run's byte count must be right even when it is not kept.
    private var trexSizes: [UInt32: UInt32] = [:]
    private var subtitleLines: [String] = []
    /// Each track's segments. A fragment cut at a video keyframe can leave a track with a run of no
    /// samples; that run is skipped rather than written, since a zero-length segment makes Apple's
    /// player give up on the whole rendition.
    private var segments: [UInt32: [(index: Int, seconds: Double)]] = [:]
    private var videoID: UInt32 = 0
    private var readySent = false

    init(directory: URL, pipe: URL, subtitles: [HLSRemuxer.SubtitleFile], subtitleOffset: TimeInterval, preferredAudio: Int?, preferredLanguage: String?, onEvent: @escaping (Event) -> Void) {
        self.directory = directory
        self.pipe = pipe
        self.subtitles = subtitles
        self.subtitleOffset = subtitleOffset
        self.preferredAudio = preferredAudio
        self.preferredLanguage = preferredLanguage
        self.onEvent = onEvent
    }

    func start() {
        let t = Thread { [self] in self.run() }
        t.name = "reel.airplay.segmenter"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Stops producing segments. The pipe is still read to the end so VLC's writer is never blocked
    /// on it; the file descriptor closes when VLC closes its side.
    func cancel() { cancelled = true }

    private func run() {
        fd = open(pipe.path, O_RDONLY)   // blocks until VLC opens the write end
        guard fd >= 0 else { onEvent(.failed("couldn't open the pipe")); return }
        defer { if fd >= 0 { close(fd); fd = -1 }; try? FileManager.default.removeItem(at: pipe) }
        var ftyp = Data()
        var haveInit = false
        var pendingMoof: Data?
        var pendingDurations: [UInt32: Double] = [:]
        var index = 0
        do {
            while true {
                if cancelled {
                    var sink = [UInt8](repeating: 0, count: 1 << 16)
                    while read(fd, &sink, sink.count) > 0 {}
                    return
                }
                guard let header = try readExact(8) else { break }   // EOF: VLC closed the pipe
                var size = UInt64(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
                let type = String(decoding: header[4..<8], as: UTF8.self)
                var headerBytes = header
                if size == 1 {
                    guard let large = try readExact(8) else { break }
                    headerBytes.append(large)
                    size = UInt64(bigEndian: large.withUnsafeBytes { $0.load(as: UInt64.self) })
                }
                guard size >= UInt64(headerBytes.count) else { throw RemuxFailure("bad box size for \(type)") }
                let payload = size - UInt64(headerBytes.count)
                switch type {
                case "ftyp", "moov", "free", "skip", "uuid", "styp", "sidx":
                    guard payload < 256 * 1024 * 1024, let body = try readExact(Int(payload)) else { throw RemuxFailure("truncated \(type)") }
                    if type == "ftyp" { ftyp = headerBytes + body }
                    if type == "moov" {
                        // VLC's moov as Apple's player needs it: sound entries version 0, HEVC as hvc1.
                        let moov = MP4Boxes.fixInit(headerBytes + body)
                        tracks = MP4Boxes.tracks(in: moov)
                        trexSizes = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.trexSize) })
                        Diagnostics.log("airplay", "tracks: " + tracks.map { "\($0.isVideo ? "video" : "audio") \($0.codec) \($0.language)" }.joined(separator: ", "))
                        guard let video = tracks.first(where: \.isVideo) else { throw RemuxFailure("no video track") }
                        // Apple's player takes only H.264 and HEVC video, and AAC, AC-3, E-AC-3, ALAC or FLAC audio,
                        // in a segment; anything else would sit there waiting. Hand back what to convert instead.
                        let unsupportedAudio = tracks.filter { !$0.isVideo && !MP4Boxes.airPlayAudio.contains($0.codec) }
                        if !MP4Boxes.airPlayVideo.contains(video.codec) || (!unsupportedAudio.isEmpty && unsupportedAudio.count == tracks.count - 1) {
                            var plan = HLSRemuxer.Plan(width: video.width, height: video.height)
                            if !MP4Boxes.airPlayVideo.contains(video.codec) { plan.video = video.codec }
                            if !unsupportedAudio.isEmpty { plan.audio = unsupportedAudio.map(\.codec) }
                            onEvent(.unsupported(plan))
                            cancelled = true
                            var sink = [UInt8](repeating: 0, count: 1 << 16)
                            while read(fd, &sink, sink.count) > 0 {}
                            return
                        }
                        tracks.removeAll { !$0.isVideo && !MP4Boxes.airPlayAudio.contains($0.codec) }
                        if !unsupportedAudio.isEmpty { Diagnostics.log("airplay", "leaving out audio AirPlay cannot carry: \(unsupportedAudio.map(\.codec).joined(separator: ", "))") }
                        videoID = video.id
                        for t in tracks {
                            try (ftyp + MP4Boxes.initSegment(moov, keeping: t.id)).write(to: directory.appendingPathComponent("init-\(t.id).mp4"), options: .atomic)
                        }
                        haveInit = true
                        subtitleLines = Self.writeSubtitleFiles(subtitles, in: directory, offset: subtitleOffset, duration: 4 * 3600)
                        writePlaylists(ended: false)
                    }
                case "moof":
                    guard payload < 64 * 1024 * 1024, let body = try readExact(Int(payload)) else { throw RemuxFailure("truncated moof") }
                    pendingMoof = headerBytes + body
                    pendingDurations = parseMoofDurations(body)
                case "mdat":
                    guard haveInit else { throw RemuxFailure("mdat before moov: output is not fragmented") }
                    guard let moof = pendingMoof else { throw RemuxFailure("mdat without moof") }
                    // Each track's run becomes its own moof + mdat; the shared mdat is routed as it streams in.
                    let runs = MP4Boxes.splitMoof(moof, trexSizes: trexSizes)
                    guard !runs.isEmpty else { throw RemuxFailure("fragment without runs") }
                    let kept = Set(tracks.map(\.id))
                    var handles: [(start: Int, end: Int, handle: FileHandle)] = []
                    for run in runs where run.samples > 0 && kept.contains(run.trackID) {
                        let url = directory.appendingPathComponent("\(run.trackID)-\(index).m4s")
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                        let h = try FileHandle(forWritingTo: url)
                        try h.write(contentsOf: run.moof)
                        try h.write(contentsOf: MP4Boxes.put32(UInt32(8 + run.bytes)) + Data("mdat".utf8))
                        handles.append((run.dataStart, run.dataStart + run.bytes, h))
                    }
                    var position = 0
                    var left = Int(payload)
                    while left > 0 {
                        guard let chunk = try readExact(min(left, 1 << 20)) else { throw RemuxFailure("truncated mdat") }
                        for h in handles {
                            let lo = max(h.start, position), hi = min(h.end, position + chunk.count)
                            if lo < hi { try h.handle.write(contentsOf: chunk[(chunk.startIndex + lo - position)..<(chunk.startIndex + hi - position)]) }
                        }
                        position += chunk.count
                        left -= chunk.count
                    }
                    for h in handles { try h.handle.close() }
                    for run in runs where run.samples > 0 && kept.contains(run.trackID) {
                        let seconds = pendingDurations[run.trackID] ?? 0
                        segments[run.trackID, default: []].append((index, seconds > 0 ? seconds : 0.001))
                    }
                    pendingMoof = nil
                    index += 1
                    writePlaylists(ended: false)
                    if !readySent, (segments[videoID]?.count ?? 0) >= 2 { readySent = true; onEvent(.ready) }
                default:
                    var left = payload
                    while left > 0 {
                        guard let chunk = try readExact(Int(min(left, 1 << 20))) else { throw RemuxFailure("truncated \(type)") }
                        left -= UInt64(chunk.count)
                    }
                }
            }
            guard !cancelled else { return }
            let video = segments[videoID] ?? []
            guard haveInit, !video.isEmpty else { throw RemuxFailure("nothing was written") }
            writePlaylists(ended: true)
            finished = true
            if !readySent { readySent = true; onEvent(.ready) }
            onEvent(.finished(segments: video.count, seconds: video.reduce(0) { $0 + $1.seconds }))
        } catch {
            if !cancelled { onEvent(.failed((error as? RemuxFailure)?.message ?? error.localizedDescription)) }
        }
    }

    struct RemuxFailure: Error { let message: String; init(_ m: String) { message = m } }

    /// Exactly `count` bytes, or nil at a clean end of stream.
    private func readExact(_ count: Int) throws -> Data? {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 1 << 20))
        while data.count < count {
            let want = min(buffer.count, count - data.count)
            let n = read(fd, &buffer, want)
            if n == 0 { return data.isEmpty ? nil : data }
            if n < 0 { if errno == EINTR { continue }; throw RemuxFailure("read failed (\(errno))") }
            data.append(buffer, count: n)
        }
        return data
    }

    // MARK: Playlists

    private func writePlaylists(ended: Bool) {
        for t in tracks {
            let list = segments[t.id] ?? []
            // The target duration must not change once the player has read it: two seconds covers
            // VLC's fragments (about 1.5 s), and a fragment is never longer than one of these.
            let target = max(2, Int((list.map(\.seconds).max() ?? 2).rounded(.up)))
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-MAP:URI=\"init-\(t.id).mp4\""]
            for s in list { lines.append(String(format: "#EXTINF:%.3f,", s.seconds)); lines.append("\(t.id)-\(s.index).m4s") }
            if ended { lines.append("#EXT-X-ENDLIST") }
            try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(Self.playlistName(t)), atomically: true, encoding: .utf8)
        }
        Self.writeMaster(in: directory, tracks: tracks, subtitleLines: subtitleLines, preferredAudio: preferredAudio, preferredLanguage: preferredLanguage)
    }

    static func playlistName(_ t: MP4Boxes.Track) -> String { t.isVideo ? "video.m3u8" : "audio-\(t.id).m3u8" }

    /// The tracks of a finished stream, read back from its init segments.
    static func tracksFromInits(in dir: URL) -> [MP4Boxes.Track] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("init-") }
        return names.flatMap { MP4Boxes.tracks(in: (try? Data(contentsOf: dir.appendingPathComponent($0))) ?? Data()) }.sorted { $0.id < $1.id }
    }

    /// WebVTT files and their one-entry playlists; returns the EXT-X-MEDIA lines for the master.
    static func writeSubtitleFiles(_ subtitles: [HLSRemuxer.SubtitleFile], in dir: URL, offset: TimeInterval, duration: TimeInterval) -> [String] {
        var lines: [String] = []
        for (i, sub) in subtitles.enumerated() {
            guard let vtt = SubtitleConversion.webVTT(from: sub.data, shiftingBy: offset) else { continue }
            let span = Int(duration.rounded(.up))
            try? vtt.write(to: dir.appendingPathComponent("sub\(i).vtt"), atomically: true, encoding: .utf8)
            let pl = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(span)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(span).000,\nsub\(i).vtt\n#EXT-X-ENDLIST\n"
            try? pl.write(to: dir.appendingPathComponent("sub\(i).m3u8"), atomically: true, encoding: .utf8)
            let name = sub.name.replacingOccurrences(of: "\"", with: "")
            lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\",LANGUAGE=\"\(sub.language)\",AUTOSELECT=NO,DEFAULT=NO,URI=\"sub\(i).m3u8\"")
        }
        return lines
    }

    /// master.m3u8: the video, every audio track as an alternate rendition, and the subtitles.
    static func writeMaster(in dir: URL, tracks: [MP4Boxes.Track], subtitleLines: [String], preferredAudio: Int?, preferredLanguage: String?) {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        let audio = tracks.filter { !$0.isVideo }
        let preferred: Int? = {
            if let p = preferredAudio, p >= 0, p < audio.count { return p }
            if let lang = preferredLanguage?.lowercased(), let i = audio.firstIndex(where: { languageMatches($0.language, lang) }) { return i }
            return audio.isEmpty ? nil : 0
        }()
        for (i, t) in audio.enumerated() {
            let def = i == preferred ? "YES" : "NO"
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(label(for: t, index: i))\",LANGUAGE=\"\(t.language)\",DEFAULT=\(def),AUTOSELECT=\(def),URI=\"\(playlistName(t))\"")
        }
        lines.append(contentsOf: subtitleLines)
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=20000000"
        if !audio.isEmpty { inf += ",AUDIO=\"aud\"" }
        if !subtitleLines.isEmpty { inf += ",SUBTITLES=\"subs\"" }
        lines.append(inf)
        lines.append("video.m3u8")
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
    }

    /// "English (AC-3)", "Japanese (AAC)", or "Track 2" when the language is unknown.
    static func label(for t: MP4Boxes.Track, index: Int) -> String {
        let codecs = ["mp4a": "AAC", "ac-3": "AC-3", "ec-3": "E-AC-3", "dtsc": "DTS", "dtsh": "DTS-HD", "dtsl": "DTS-HD MA", "dtse": "DTS Express", "mlpa": "TrueHD", "Opus": "Opus", "fLaC": "FLAC", ".mp3": "MP3"]
        let name = t.language == "und" ? "Track \(index + 1)" : (Locale.current.localizedString(forLanguageCode: t.language) ?? t.language)
        if let c = codecs[t.codec] { return "\(name) (\(c))" }
        return name
    }

    /// ISO 639-2 in the file against a two- or three-letter preference.
    static func languageMatches(_ trackLang: String, _ wanted: String) -> Bool {
        if trackLang == wanted { return true }
        guard let locale = Locale(identifier: trackLang).language.languageCode?.identifier.lowercased() else { return false }
        let w = Locale(identifier: wanted).language.languageCode?.identifier.lowercased() ?? wanted
        return locale == w || Locale(identifier: wanted).language.languageCode?.identifier(.alpha3) == trackLang
    }

    // MARK: Durations

    /// Each track's run duration in seconds, from its trun (or tfhd default) in the fragment.
    private func parseMoofDurations(_ body: Data) -> [UInt32: Double] {
        let scales = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.timescale) })
        var out: [UInt32: Double] = [:]
        MP4Boxes.forEachBox(in: body) { type, payload in
            guard type == "traf" else { return }
            var trackID: UInt32 = 0, defaultDuration: UInt32 = 0, total: UInt64 = 0
            MP4Boxes.forEachBox(in: payload) { t, p in
                if t == "tfhd", p.count >= 8 {
                    let flags = MP4Boxes.be32(p, p.startIndex) & 0xFFFFFF
                    trackID = MP4Boxes.be32(p, p.startIndex + 4)
                    var off = 8
                    if flags & 0x1 != 0 { off += 8 }
                    if flags & 0x2 != 0 { off += 4 }
                    if flags & 0x8 != 0, p.count >= off + 4 { defaultDuration = MP4Boxes.be32(p, p.startIndex + off) }
                }
                if t == "trun", p.count >= 8 {
                    let flags = MP4Boxes.be32(p, p.startIndex) & 0xFFFFFF
                    let count = Int(MP4Boxes.be32(p, p.startIndex + 4))
                    var off = 8
                    if flags & 0x1 != 0 { off += 4 }
                    if flags & 0x4 != 0 { off += 4 }
                    let per = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0) + (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                    if flags & 0x100 != 0 {
                        for i in 0..<count where p.count >= off + i * per + 4 { total += UInt64(MP4Boxes.be32(p, p.startIndex + off + i * per)) }
                    } else {
                        total += UInt64(count) * UInt64(defaultDuration)
                    }
                }
            }
            guard let scale = scales[trackID], scale > 0 else { return }
            out[trackID] = Double(total) / Double(scale)
        }
        return out
    }
}
#endif
