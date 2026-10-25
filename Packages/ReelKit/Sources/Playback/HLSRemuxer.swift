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
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Another AirPlay stream is still being prepared."
            case .failed(let m): "Couldn't prepare this file for AirPlay: \(m)"
            case .notFragmented: "Couldn't prepare this file for AirPlay: the copy was not streamable."
            case .timeout: "Couldn't prepare this file for AirPlay: nothing arrived from the file in time."
            }
        }
    }

    private var player: VLCMediaPlayer?
    private var segmenter: Segmenter?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var currentDirectory: URL?
    /// What the segmenter reported before anyone was waiting for it (it can fail within a frame).
    private var outcome: Result<Void, Error>?

    /// A finished stream for `key`, if there is one.
    public static func completed(for key: String) -> URL? {
        let dir = directory.appendingPathComponent(folderName(key), isDirectory: true)
        let playlist = dir.appendingPathComponent("index.m3u8")
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

    /// The playlist to hand to the player: master.m3u8 when subtitles were written, else index.m3u8.
    public static func playlistName(in directory: URL) -> String {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("master.m3u8").path) ? "master.m3u8" : "index.m3u8"
    }

    /// `audioTrack` is the index among the file's audio tracks to copy (VLC's order); nil leaves it
    /// to `audioLanguage`, then VLC's default. A copy of a non-default track is not kept.
    public func start(source: URL, key: String, startAt: TimeInterval, subtitles: [SubtitleFile] = [], audioTrack: Int? = nil, audioLanguage: String? = nil) async throws -> URL {
        if startAt <= 0, audioTrack == nil, let done = Self.completed(for: key) {
            Self.writeSubtitles(subtitles, in: done, offset: 0, duration: Self.duration(of: done))
            return done
        }
        guard player == nil else { throw RemuxError.alreadyRunning }
        let dir = Self.directory.appendingPathComponent(Self.folderName(key) + (startAt > 0 || audioTrack != nil ? "-partial" : ""), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pipe = dir.appendingPathComponent("pipe")
        guard mkfifo(pipe.path, 0o600) == 0 else { throw RemuxError.failed("couldn't make a pipe") }
        currentDirectory = dir
        outcome = nil

        guard let media = VLCMedia(url: source) else { throw RemuxError.failed("VLC couldn't open the file") }
        // mp4frag is VLC 4's fragmented, streamable MP4 muxer: index first, then moof/mdat fragments.
        media.addOption(":sout=#std{access=file,mux=mp4frag,dst=\(pipe.path)}")
        media.addOption(":no-sout-keep")
        media.addOption(":no-sout-display")
        media.addOption(":sout-mux-caching=300")
        media.addOption(":network-caching=3000")
        if startAt > 0 { media.addOption(":start-time=\(Int(startAt))") }
        if let audioTrack { media.addOption(":audio-track=\(audioTrack)") }
        else if let audioLanguage { media.addOption(":audio-language=\(audioLanguage)") }
        let p = VLCMediaPlayer()
        p.delegate = self
        player = p
        p.media = media

        let seg = Segmenter(directory: dir, pipe: pipe) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Subtitles are written up front with a generous span; the main playlist grows underneath.
        Self.writeSubtitles(subtitles, in: dir, offset: startAt, duration: 4 * 3600)
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
            if let dir { try? await Task.sleep(for: .seconds(1)); try? FileManager.default.removeItem(at: dir) }
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

    /// WebVTT renditions and a master playlist that lists them next to the video.
    static func writeSubtitles(_ subtitles: [SubtitleFile], in dir: URL, offset: TimeInterval, duration: TimeInterval) {
        var media: [String] = []
        for (i, sub) in subtitles.enumerated() {
            guard let vtt = SubtitleConversion.webVTT(from: sub.data, shiftingBy: offset) else { continue }
            let vttName = "sub\(i).vtt", plName = "sub\(i).m3u8"
            try? vtt.write(to: dir.appendingPathComponent(vttName), atomically: true, encoding: .utf8)
            let span = Int(duration.rounded(.up))
            let pl = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(span)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(span).000,\n\(vttName)\n#EXT-X-ENDLIST\n"
            try? pl.write(to: dir.appendingPathComponent(plName), atomically: true, encoding: .utf8)
            let name = sub.name.replacingOccurrences(of: "\"", with: "")
            media.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\",LANGUAGE=\"\(sub.language)\",AUTOSELECT=NO,DEFAULT=NO,URI=\"\(plName)\"")
        }
        let master = dir.appendingPathComponent("master.m3u8")
        guard !media.isEmpty else { try? FileManager.default.removeItem(at: master); return }
        let text = (["#EXTM3U", "#EXT-X-VERSION:7"] + media + ["#EXT-X-STREAM-INF:BANDWIDTH=20000000,SUBTITLES=\"subs\"", "index.m3u8"]).joined(separator: "\n") + "\n"
        try? text.write(to: master, atomically: true, encoding: .utf8)
    }

    private static func duration(of dir: URL) -> TimeInterval {
        let text = (try? String(contentsOf: dir.appendingPathComponent("index.m3u8"), encoding: .utf8)) ?? ""
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
        (try? String(contentsOf: dir.appendingPathComponent("index.m3u8"), encoding: .utf8))?.contains("#EXT-X-ENDLIST") ?? false
    }
}

// MARK: - Segmenter

/// Reads the fragmented MP4 from the pipe on its own thread and writes init.mp4, segN.m4s and
/// index.m3u8 into the folder.
final class Segmenter: @unchecked Sendable {
    enum Event { case ready, finished(segments: Int, seconds: Double), failed(String) }

    private let directory: URL
    private let pipe: URL
    private let onEvent: (Event) -> Void
    private var fd: Int32 = -1
    private var cancelled = false
    private(set) var finished = false
    private var thread: Thread?

    // Parsed from moov: track id → timescale, and which track is video.
    private var timescales: [UInt32: UInt32] = [:]
    private var trexSizes: [UInt32: UInt32] = [:]
    private var videoTrack: UInt32?
    private var segments: [(name: String, seconds: Double)] = []
    private var readySent = false

    init(directory: URL, pipe: URL, onEvent: @escaping (Event) -> Void) {
        self.directory = directory
        self.pipe = pipe
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
        // Opening the read end blocks until VLC opens the write end.
        fd = open(pipe.path, O_RDONLY)
        guard fd >= 0 else { onEvent(.failed("couldn't open the pipe")); return }
        defer { if fd >= 0 { close(fd); fd = -1 }; try? FileManager.default.removeItem(at: pipe) }
        var initData = Data()
        var pendingMoof: Data?
        var pendingDuration = 0.0
        var index = 0
        do {
            while true {
                if cancelled {
                    // Drain and discard until EOF.
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
                guard size >= UInt64(headerBytes.count) else {
                    throw RemuxFailure("bad box size for \(type): \(headerBytes.map { String(format: "%02x", $0) }.joined())")
                }
                let payload = size - UInt64(headerBytes.count)
                switch type {
                case "ftyp", "moov", "free", "skip", "uuid", "styp", "sidx":
                    guard payload < 256 * 1024 * 1024, let body = try readExact(Int(payload)) else { throw RemuxFailure("truncated \(type)") }
                    if type == "ftyp" { initData = headerBytes + body }
                    if type == "moov" {
                        // VLC's moov as Apple's player needs it: sound entries version 0, HEVC as hvc1.
                        let moov = MP4Boxes.fixInit(headerBytes + body)
                        trexSizes = MP4Boxes.trexSizes(moov)
                        parseMoov(body)
                        initData.append(moov)
                        try initData.write(to: directory.appendingPathComponent("init.mp4"), options: .atomic)
                        writePlaylist(ended: false)
                    }
                case "moof":
                    guard payload < 64 * 1024 * 1024, let body = try readExact(Int(payload)) else { throw RemuxFailure("truncated moof") }
                    // Explicit, moof-relative data offsets for every run; VLC leaves the audio run's implicit.
                    pendingMoof = MP4Boxes.fixMoof(headerBytes + body, trexSizes: trexSizes)
                    pendingDuration = parseMoofDuration(body)
                case "mdat":
                    guard !initData.isEmpty else { throw RemuxFailure("mdat before moov: output is not fragmented") }
                    guard let moof = pendingMoof else { throw RemuxFailure("mdat without moof") }
                    let name = "seg\(index).m4s"
                    let url = directory.appendingPathComponent(name)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    let out = try FileHandle(forWritingTo: url)
                    try out.write(contentsOf: moof)
                    try out.write(contentsOf: headerBytes)
                    var left = payload
                    while left > 0 {
                        let want = Int(min(left, 1 << 20))
                        guard let chunk = try readExact(want) else { throw RemuxFailure("truncated mdat") }
                        try out.write(contentsOf: chunk)
                        left -= UInt64(chunk.count)
                    }
                    try out.close()
                    segments.append((name, pendingDuration > 0 ? pendingDuration : 2))
                    pendingMoof = nil
                    index += 1
                    writePlaylist(ended: false)
                    if !readySent, segments.count >= 2 { readySent = true; onEvent(.ready) }
                default:
                    // Anything else is skipped, streaming it past.
                    var left = payload
                    while left > 0 {
                        let want = Int(min(left, 1 << 20))
                        guard let chunk = try readExact(want) else { throw RemuxFailure("truncated \(type)") }
                        left -= UInt64(chunk.count)
                    }
                }
            }
            guard !cancelled else { return }
            guard !initData.isEmpty, !segments.isEmpty else { throw RemuxFailure("nothing was written") }
            writePlaylist(ended: true)
            finished = true
            if !readySent { readySent = true; onEvent(.ready) }
            onEvent(.finished(segments: segments.count, seconds: segments.reduce(0) { $0 + $1.seconds }))
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
            if n == 0 { return data.isEmpty ? nil : data }   // EOF
            if n < 0 { if errno == EINTR { continue }; throw RemuxFailure("read failed (\(errno))") }
            data.append(buffer, count: n)
        }
        return data
    }

    private func writePlaylist(ended: Bool) {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int((segments.map(\.seconds).max() ?? 2).rounded(.up))))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-MAP:URI=\"init.mp4\""]
        for s in segments { lines.append(String(format: "#EXTINF:%.3f,", s.seconds)); lines.append(s.name) }
        if ended { lines.append("#EXT-X-ENDLIST") }
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }

    // MARK: Box parsing

    /// Walks `trak` boxes for track ids, timescales and the video handler.
    private func parseMoov(_ body: Data) {
        forEachBox(in: body) { type, payload in
            guard type == "trak" else { return }
            var id: UInt32 = 0, scale: UInt32 = 0, isVideo = false
            forEachBox(in: payload) { t, p in
                if t == "tkhd", p.count >= 20 {
                    let version = p[p.startIndex]
                    id = version == 1 ? be32(p, 20) : be32(p, 12)
                }
                if t == "mdia" {
                    forEachBox(in: p) { mt, mp in
                        if mt == "mdhd", mp.count >= 20 { scale = mp[mp.startIndex] == 1 ? be32(mp, 20) : be32(mp, 12) }
                        if mt == "hdlr", mp.count >= 12 { isVideo = String(decoding: mp[(mp.startIndex + 8)..<(mp.startIndex + 12)], as: UTF8.self) == "vide" }
                    }
                }
            }
            if id > 0, scale > 0 { timescales[id] = scale; if isVideo { videoTrack = id } }
        }
    }

    /// The fragment's duration in seconds, from the video track's trun (or the first traf).
    private func parseMoofDuration(_ body: Data) -> Double {
        var best = 0.0
        var first = 0.0
        forEachBox(in: body) { type, payload in
            guard type == "traf" else { return }
            var trackID: UInt32 = 0, defaultDuration: UInt32 = 0, total: UInt64 = 0
            forEachBox(in: payload) { t, p in
                if t == "tfhd", p.count >= 8 {
                    let flags = be32(p, 0) & 0xFFFFFF
                    trackID = be32(p, 4)
                    var off = 8
                    if flags & 0x1 != 0 { off += 8 }
                    if flags & 0x2 != 0 { off += 4 }
                    if flags & 0x8 != 0, p.count >= off + 4 { defaultDuration = be32(p, off) }
                }
                if t == "trun", p.count >= 8 {
                    let flags = be32(p, 0) & 0xFFFFFF
                    let count = Int(be32(p, 4))
                    var off = 8
                    if flags & 0x1 != 0 { off += 4 }
                    if flags & 0x4 != 0 { off += 4 }
                    let perSample = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0) + (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                    if flags & 0x100 != 0 {
                        for i in 0..<count where p.count >= off + i * perSample + 4 { total += UInt64(be32(p, off + i * perSample)) }
                    } else {
                        total += UInt64(count) * UInt64(defaultDuration)
                    }
                }
            }
            guard let scale = timescales[trackID], scale > 0 else { return }
            let seconds = Double(total) / Double(scale)
            if first == 0 { first = seconds }
            if trackID == videoTrack { best = seconds }
        }
        return best > 0 ? best : first
    }

    private func forEachBox(in data: Data, _ body: (String, Data) -> Void) {
        var off = data.startIndex
        while off + 8 <= data.endIndex {
            var size = Int(be32(data, off - data.startIndex))
            let type = String(decoding: data[(off + 4)..<(off + 8)], as: UTF8.self)
            var headerLength = 8
            if size == 1, off + 16 <= data.endIndex {
                size = Int(UInt64(bigEndian: data[(off + 8)..<(off + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))
                headerLength = 16
            }
            if size == 0 { size = data.endIndex - off }
            guard size >= headerLength, off + size <= data.endIndex else { return }
            body(type, data[(off + headerLength)..<(off + size)])
            off += size
        }
    }

    private func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 4 <= data.endIndex else { return 0 }
        return UInt32(bigEndian: data[i..<(i + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }
}
#endif
