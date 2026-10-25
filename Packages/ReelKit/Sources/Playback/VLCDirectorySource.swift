#if canImport(VLCKit)
import Foundation
import VLCKit
import MediaCore
import MediaSources

/// SFTP and NFS through VLC itself. VLCKit ships the sftp and nfs access modules, and a directory
/// URL parsed with the network option lists its entries (with size and modified time), so the
/// library can scan these servers without another SSH or NFS library. Playback is VLC's own URL.
/// Downloads use VLC's dump demuxer, which copies the raw stream to a file. Ranged reads are not
/// available, so AirPlay of these files goes through the HLS copy (VLC reads, Apple's player plays).
public actor VLCDirectorySource: MediaSource {
    public let config: SourceConfig
    private var credentials: Credentials?

    public init(config: SourceConfig) { self.config = config }

    public nonisolated var supportsRangedReads: Bool { false }

    /// Registers this source for the types VLC handles, so `SourceFactory` builds it for them.
    public static func register() {
        SourceFactory.vlcBackedMaker = { VLCDirectorySource(config: $0) }
    }

    public func connect(credentials: Credentials?) async throws {
        self.credentials = credentials
        _ = try await list("")
    }

    public func list(_ relativePath: String) async throws -> [DirectoryEntry] {
        let url = try url(for: relativePath, directory: true, embedCredentials: false)
        let items = try await Self.parseDirectory(url, options: options())
        return items.compactMap { item -> DirectoryEntry? in
            guard let itemURL = item.url else { return nil }
            let name = itemURL.lastPathComponent.removingPercentEncoding ?? itemURL.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return nil }
            let isDir = item.mediaType == .directory || itemURL.absoluteString.hasSuffix("/")
            var size: UInt64 = 0, mtime: UInt64 = 0
            let hasSize = item.fileStatValue(for: .size, value: &size) == .success
            let hasTime = item.fileStatValue(for: .mtime, value: &mtime) == .success
            let rel = relativePath.isEmpty ? name : relativePath + "/" + name
            return DirectoryEntry(name: name, relativePath: rel, isDirectory: isDir, size: hasSize && !isDir ? Int64(size) : nil, modified: hasTime && mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil)
        }.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        let name = (relativePath as NSString).lastPathComponent
        let parent = (relativePath as NSString).deletingLastPathComponent
        guard let found = try await list(parent).first(where: { $0.name == name }) else { throw SourceError.notFound(relativePath) }
        return found
    }

    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL {
        if let credentials { self.credentials = credentials }
        return try url(for: relativePath, directory: false, embedCredentials: true)
    }

    /// VLC's dump demuxer writes the raw bytes of the stream to a file, which for a media file is a copy.
    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        let total = (try? await stat(relativePath).size) ?? 0
        let url = try url(for: relativePath, directory: false, embedCredentials: true)
        try? FileManager.default.removeItem(at: destination)
        let copier = await Dumper(url: url, destination: destination, options: options())
        try await copier.run { written in progress(written, total) }
        _ = progress((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0, total)
    }

    public func disconnect() async {}

    // MARK: -

    private func url(for relativePath: String, directory: Bool, embedCredentials: Bool) throws -> URL {
        var c = URLComponents()
        c.scheme = config.type.vlcScheme ?? "sftp"
        c.host = config.host
        c.port = config.port
        if embedCredentials, config.type != .nfs, let creds = credentials, !creds.username.isEmpty {
            c.user = creds.username
            c.password = creds.password
        }
        let base = config.path.hasPrefix("/") ? config.path : "/" + config.path
        let parts = base.split(separator: "/").map(String.init) + relativePath.split(separator: "/").map(String.init)
        c.path = "/" + parts.joined(separator: "/") + (directory && !parts.isEmpty ? "/" : "")
        guard let url = c.url else { throw SourceError.notFound(relativePath) }
        return url
    }

    /// Credentials as VLC options rather than in the listing URL, so they never show in a log line.
    private func options() -> [String] {
        guard config.type == .sftp, let creds = credentials, !creds.username.isEmpty else { return [] }
        return [":sftp-user=\(creds.username)", ":sftp-pwd=\(creds.password)"]
    }

    /// Lists a directory URL through libvlc's parser. Runs on the main actor because VLCKit delivers
    /// its parse callbacks there.
    @MainActor
    private static func parseDirectory(_ url: URL, options: [String]) async throws -> [VLCMedia] {
        guard let media = VLCMedia(url: url) else { throw SourceError.notFound(url.lastPathComponent) }
        for o in options { media.addOption(o) }
        let watcher = ParseWatcher()
        media.delegate = watcher
        let result = media.parse(options: [.parseNetwork], timeout: 20000)
        guard result == 0 else { throw SourceError.unreachable(url.host ?? "") }
        try await watcher.wait()
        media.delegate = nil
        switch media.parsedStatus {
        case .done: break
        case .timeout: throw SourceError.unreachable(url.host ?? "")
        default:
            Diagnostics.log("source", "\(url.scheme ?? "") \(url.host ?? ""): listing failed (\(media.parsedStatus.rawValue)) for \(Diagnostics.safe(url))")
            throw SourceError.notFound(url.lastPathComponent)
        }
        guard let list = media.subitems else { return [] }
        return (0..<list.count).compactMap { list.media(at: UInt($0)) }
    }

    private final class ParseWatcher: NSObject, VLCMediaDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        func wait() async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in continuation = c }
        }
        func mediaDidFinishParsing(_ aMedia: VLCMedia) {
            finished = true
            continuation?.resume(); continuation = nil
        }
    }

    /// Plays a URL into VLC's dump demuxer until the stream ends, reporting the file's growth.
    @MainActor
    private final class Dumper: NSObject, VLCMediaPlayerDelegate {
        private let player = VLCMediaPlayer()
        private let destination: URL
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        init(url: URL, destination: URL, options: [String]) {
            self.destination = destination
            super.init()
            let media = VLCMedia(url: url)!
            for o in options { media.addOption(o) }
            media.addOption(":demux=dump")
            media.addOption(":demuxdump-file=\(destination.path)")
            media.addOption(":no-sout-display")
            media.addOption(":network-caching=3000")
            player.media = media
            player.delegate = self
        }

        func run(progress: @escaping @Sendable (Int64) -> Bool) async throws {
            player.play()
            let poll = Task { @MainActor [weak self] in
                while let self, !self.done {
                    try? await Task.sleep(for: .milliseconds(500))
                    let size = (try? FileManager.default.attributesOfItem(atPath: self.destination.path)[.size] as? Int64) ?? 0
                    if !progress(size) { self.finish(.failure(CancellationError())); return }
                }
            }
            defer { poll.cancel() }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if done { c.resume() } else { continuation = c }
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard !done else { return }
            done = true
            player.stop()
            continuation?.resume(with: result); continuation = nil
        }

        nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
            Task { @MainActor in
                switch newState {
                case .stopped: self.finish(.success(()))
                case .error: self.finish(.failure(SourceError.unreachable(self.player.media?.url?.host ?? "")))
                default: break
                }
            }
        }
    }
}
#endif
