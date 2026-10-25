import Foundation
import Network
import MediaCore

/// A tiny HTTP server on 127.0.0.1 that serves one file from a share with Range support, so
/// AVPlayer can play an MP4 or MOV that lives on SMB or WebDAV. AVPlayer is the only way to send
/// video (not just audio) over AirPlay, and it cannot read SMB itself. Each request becomes
/// `MediaSource.read` calls of about a megabyte, sent as they arrive, so seeking is cheap and
/// nothing is downloaded ahead of what the player asks for.
///
/// One registration at a time: `register` returns the URL to hand to AVPlayer and drops whatever
/// was registered before. `stop` closes the listener and the source.
public actor StreamBridge {
    public static let shared = StreamBridge()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var entry: Entry?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private static let chunk = 1 << 20

    struct Entry {
        var token: String
        var source: any MediaSource
        var path: String
        var size: Int64
        var contentType: String
        var fileName: String
    }

    /// Serves `path` from `source` (already connected) and returns the local URL for it.
    public func register(source: any MediaSource, path: String, size: Int64) async throws -> URL {
        try await start()
        let token = UUID().uuidString.lowercased()
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let type = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime"][ext] ?? "application/octet-stream"
        if let old = entry { await old.source.disconnect() }
        entry = Entry(token: token, source: source, path: path, size: size, contentType: type, fileName: name)
        let safeName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video.mp4"
        Diagnostics.log("bridge", "serving \(name) (\(size / 1_000_000) MB) on port \(port)")
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(safeName)")!
    }

    /// Closes the listener and disconnects the source.
    public func stop() async {
        for c in connections.values { c.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        if let e = entry { await e.source.disconnect() }
        entry = nil
        Diagnostics.log("bridge", "stopped")
    }

    private func start() async throws {
        if listener != nil { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume()
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                case .cancelled: resumed = true; cont.resume(throwing: SourceError.unsupported("bridge cancelled"))
                default: break
                }
            }
            l.start(queue: DispatchQueue(label: "reel.bridge.listener"))
        }
        port = l.port?.rawValue ?? 0
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.forget(connection) } }
            if case .cancelled = state { Task { await self?.forget(connection) } }
        }
        connection.start(queue: DispatchQueue(label: "reel.bridge.connection"))
        Task { await self.serve(connection) }
    }

    private func forget(_ connection: NWConnection) { connections[ObjectIdentifier(connection)] = nil }

    // MARK: - One request per connection

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let head = await readHead(connection) else { return }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return }
        let method = parts[0], target = parts[1]
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        guard let entry, target.hasPrefix("/" + entry.token + "/") else {
            await send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        // Range: bytes=start-end | bytes=start- | bytes=-suffix
        var start: Int64 = 0, end: Int64 = entry.size - 1
        var partial = false
        if let r = headers["range"], r.hasPrefix("bytes=") {
            let spec = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if spec.count == 2 {
                if spec[0].isEmpty, let suffix = Int64(spec[1]) { start = max(0, entry.size - suffix) }
                else if let s = Int64(spec[0]) { start = s; if let e = Int64(spec[1]) { end = min(e, entry.size - 1) } }
                partial = true
            }
        }
        if start > end || start >= entry.size {
            await send(connection, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(entry.size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let length = end - start + 1
        var head2 = partial ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(entry.size)\r\n" : "HTTP/1.1 200 OK\r\n"
        head2 += "Content-Type: \(entry.contentType)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        guard await send(connection, head2) else { return }
        if method == "HEAD" { return }
        var offset = start
        while offset <= end {
            let want = Int(min(Int64(Self.chunk), end - offset + 1))
            let data: Data
            do { data = try await entry.source.read(entry.path, offset: offset, length: want) } catch {
                Diagnostics.log("bridge", "read failed at \(offset): \(error.localizedDescription)")
                return
            }
            if data.isEmpty { return }
            guard await send(connection, data) else { return }
            offset += Int64(data.count)
        }
    }

    private func readHead(_ connection: NWConnection) async -> String? {
        var buffer = Data()
        while buffer.count < 16 * 1024 {
            let piece: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if error != nil || (isComplete && data == nil) { cont.resume(returning: nil) } else { cont.resume(returning: data ?? Data()) }
                }
            }
            guard let piece else { return nil }
            buffer.append(piece)
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) { return String(data: buffer[..<range.lowerBound], encoding: .utf8) }
        }
        return nil
    }

    @discardableResult
    private func send(_ connection: NWConnection, _ string: String) async -> Bool { await send(connection, Data(string.utf8)) }

    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { error in cont.resume(returning: error == nil) })
        }
    }
}
