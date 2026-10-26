#if canImport(Network)
import Foundation
import Network
import MediaCore

/// Plain FTP, with Reel's own small client: a control connection for commands and a passive data
/// connection per transfer. MLSD for listings (LIST as the fallback for older servers), SIZE and
/// MDTM for stat, REST + RETR for the ranged reads the AirPlay bridge needs. Playback hands VLC an
/// `ftp://` URL so it does its own buffering. TLS is not offered: FTPS is rare on home servers, and
/// a seedbox usually has SFTP or WebDAV as well.
public actor FTPSource: MediaSource {
    public let config: SourceConfig
    private var credentials: Credentials?
    private var control: FTPControl?
    /// True once MLSD has been refused, so later listings go straight to LIST.
    private var useLIST = false

    public init(config: SourceConfig) { self.config = config }

    private var port: UInt16 { UInt16(config.port ?? 21) }

    public func connect(credentials: Credentials?) async throws {
        self.credentials = credentials
        try await open()
    }

    private func open() async throws {
        control?.close()
        control = nil
        let c = FTPControl(host: config.host, port: port)
        do {
            try await c.start()
            let greeting = try await c.readReply()
            guard greeting.code / 100 == 2 else { throw SourceError.unreachable(config.host) }
            let user = try await c.send("USER \(credentials?.username ?? "anonymous")")
            if user.code == 331 {
                let pass = try await c.send("PASS \(credentials?.password ?? "reel@")")
                guard pass.code / 100 == 2 else { throw SourceError.authFailed }
            } else if user.code / 100 != 2 {
                throw SourceError.authFailed
            }
            _ = try await c.send("TYPE I")
        } catch let e as SourceError {
            c.close()
            Diagnostics.log("source", "ftp \(config.host): \(e)")
            throw e
        } catch {
            c.close()
            Diagnostics.log("source", "ftp \(config.host): \(error.localizedDescription)")
            throw SourceError.unreachable(config.host)
        }
        control = c
    }

    /// The control connection, reopened if the server dropped it between calls.
    private func session() async throws -> FTPControl {
        if let control, control.isOpen { return control }
        try await open()
        guard let control else { throw SourceError.unreachable(config.host) }
        return control
    }

    public func list(_ relativePath: String) async throws -> [DirectoryEntry] {
        let path = absolute(relativePath)
        let c = try await session()
        var entries: [FTPListing.Entry] = []
        if !useLIST {
            do {
                let data = try await c.transfer("MLSD \(path)")
                entries = FTPListing.parseMLSD(String(decoding: data, as: UTF8.self))
            } catch FTPControl.Failure.refused(let code) where code == 500 || code == 502 || code == 550 {
                useLIST = true
            }
        }
        if useLIST {
            let data = try await c.transfer("LIST \(path)")
            entries = FTPListing.parseLIST(String(decoding: data, as: UTF8.self))
        }
        return entries.compactMap { e -> DirectoryEntry? in
            guard e.name != "." && e.name != "..", !e.name.hasPrefix(".") else { return nil }
            let rel = relativePath.isEmpty ? e.name : relativePath + "/" + e.name
            return DirectoryEntry(name: e.name, relativePath: rel, isDirectory: e.isDirectory, size: e.size, modified: e.modified)
        }.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func stat(_ relativePath: String) async throws -> DirectoryEntry {
        let path = absolute(relativePath)
        let c = try await session()
        let name = (relativePath as NSString).lastPathComponent
        let size = try await c.send("SIZE \(path)")
        if size.code == 213, let bytes = Int64(size.text.trimmingCharacters(in: .whitespaces)) {
            var modified: Date?
            let mdtm = try await c.send("MDTM \(path)")
            if mdtm.code == 213 { modified = FTPListing.date(fromMLSD: mdtm.text.trimmingCharacters(in: .whitespaces)) }
            return DirectoryEntry(name: name, relativePath: relativePath, isDirectory: false, size: bytes, modified: modified)
        }
        // SIZE is refused for directories (and by some servers altogether): find it in the parent's listing.
        let parent = (relativePath as NSString).deletingLastPathComponent
        if let found = try await list(parent).first(where: { $0.name == name }) { return found }
        throw SourceError.notFound(relativePath)
    }

    public func playbackURL(_ relativePath: String, credentials: Credentials?) async throws -> URL {
        var c = URLComponents()
        c.scheme = "ftp"
        c.host = config.host
        c.port = config.port
        if let creds = credentials ?? self.credentials {
            c.user = creds.username
            c.password = creds.password
        }
        c.path = absolute(relativePath)
        guard let url = c.url else { throw SourceError.notFound(relativePath) }
        return url
    }

    public func download(_ relativePath: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Bool) async throws {
        let total = (try? await stat(relativePath).size) ?? 0
        let c = try await session()
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        try await c.transfer("RETR \(absolute(relativePath))") { chunk in
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            return progress(written, total)
        }
        _ = progress(written, total > 0 ? total : written)
    }

    public func read(_ relativePath: String, offset: Int64, length: Int) async throws -> Data {
        let c = try await session()
        if offset > 0 {
            let rest = try await c.send("REST \(offset)")
            guard rest.code == 350 else { throw SourceError.unsupported("resuming on this FTP server") }
        }
        var data = Data()
        data.reserveCapacity(length)
        try await c.transfer("RETR \(absolute(relativePath))") { chunk in
            data.append(chunk)
            return data.count < length   // enough: the data connection is dropped and the server told
        }
        return data.count > length ? data.prefix(length) : data
    }

    public func disconnect() async {
        if let control { _ = try? await control.send("QUIT"); control.close() }
        control = nil
    }

    /// The server-side path for a library-relative one, under the configured folder.
    private func absolute(_ relativePath: String) -> String {
        let base = config.path.hasPrefix("/") ? config.path : "/" + config.path
        let parts = base.split(separator: "/").map(String.init) + relativePath.split(separator: "/").map(String.init)
        return "/" + parts.joined(separator: "/")
    }
}

// MARK: - Control connection

/// One FTP control connection: sends a command, reads its reply (multi-line replies included), and
/// opens passive data connections for transfers. Not an actor; `FTPSource` serialises its use.
final class FTPControl: @unchecked Sendable {
    enum Failure: Error { case closed, timeout, refused(Int), badReply(String) }

    private let host: String
    private let port: UInt16
    private let connection: NWConnection
    private var buffer = Data()
    private(set) var isOpen = false
    private let timeout: TimeInterval = 20

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func start() async throws {
        try await Self.ready(connection, timeout: timeout)
        isOpen = true
    }

    func close() {
        isOpen = false
        connection.cancel()
    }

    /// Waits for a connection to become ready, or fails.
    static func ready(_ connection: NWConnection, timeout: TimeInterval) async throws {
        try await withTimeout(timeout, onTimeout: { connection.cancel() }) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = OnceGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { cont.resume() }
                    case .failed(let e): once.run { cont.resume(throwing: e) }
                    case .cancelled: once.run { cont.resume(throwing: Failure.closed) }
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    func send(_ command: String) async throws -> (code: Int, text: String) {
        try await write(Data((command + "\r\n").utf8))
        return try await readReply()
    }

    private func write(_ data: Data) async throws {
        let connection = self.connection
        try await withTimeout(timeout, onTimeout: { connection.cancel() }) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
    }

    /// The next reply: "220 text", or "220-first\r\n...\r\n220 last" for a multi-line one.
    func readReply() async throws -> (code: Int, text: String) {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                if lines.count == 1 { throw Failure.badReply(line) } else { continue }
            }
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                let text = lines.count == 1 ? String(line.dropFirst(4)) : lines.map { $0.count > 4 && Int($0.prefix(3)) == code ? String($0.dropFirst(4)) : $0 }.joined(separator: "\n")
                return (code, text)
            }
            // "220-": a continuation; keep reading until the "220 " line.
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            let (chunk, done) = try await Self.receive(connection, timeout: timeout)
            buffer.append(chunk)
            if done, buffer.isEmpty { isOpen = false; throw Failure.closed }
            if done { isOpen = false; let rest = String(decoding: buffer, as: UTF8.self); buffer.removeAll(); return rest }
        }
    }

    static func receive(_ connection: NWConnection, timeout: TimeInterval) async throws -> (Data, Bool) {
        try await withTimeout(timeout, onTimeout: { connection.cancel() }) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data ?? Data(), complete)) }
                }
            }
        }
    }

    /// Runs a data-connection command (MLSD, LIST, RETR) and returns everything the server sent.
    func transfer(_ command: String) async throws -> Data {
        var out = Data()
        try await transfer(command) { out.append($0); return true }
        return out
    }

    /// Runs a data-connection command, handing each chunk to `sink`; a false from the sink stops
    /// the transfer early (the data connection is dropped and the server's complaint read and ignored).
    func transfer(_ command: String, sink: (Data) throws -> Bool) async throws {
        let dataConnection = try await openPassive()
        defer { dataConnection.cancel() }
        let started = try await send(command)
        guard started.code == 150 || started.code == 125 else {
            if started.code == 550 || started.code == 500 || started.code == 502 { throw Failure.refused(started.code) }
            throw Failure.badReply("\(started.code) \(started.text)")
        }
        var stopped = false
        while true {
            let (chunk, done) = try await Self.receive(dataConnection, timeout: timeout)
            if !chunk.isEmpty, try !sink(chunk) { stopped = true; break }
            if done { break }
        }
        dataConnection.cancel()
        // 226 on success; 426 or 451 when the data connection was dropped on purpose.
        let final = try await readReply()
        if !stopped, final.code / 100 != 2 { throw Failure.badReply("\(final.code) \(final.text)") }
    }

    /// EPSV (works through NAT and on IPv6), with PASV as the fallback.
    private func openPassive() async throws -> NWConnection {
        var dataPort: UInt16?
        var dataHost = host
        let epsv = try await send("EPSV")
        if epsv.code == 229, let open = epsv.text.lastIndex(of: "("), let close = epsv.text.lastIndex(of: ")") {
            let inner = epsv.text[epsv.text.index(after: open)..<close].split(separator: "|", omittingEmptySubsequences: true)
            if let last = inner.last, let p = UInt16(last) { dataPort = p }
        }
        if dataPort == nil {
            let pasv = try await send("PASV")
            guard pasv.code == 227, let open = pasv.text.lastIndex(of: "("), let close = pasv.text.lastIndex(of: ")") else { throw Failure.badReply("\(pasv.code) \(pasv.text)") }
            let numbers = pasv.text[pasv.text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 6 else { throw Failure.badReply(pasv.text) }
            // The advertised address is trusted only when it is not a private-behind-NAT mismatch;
            // the control connection's host is what reached the server, so it is used throughout.
            dataHost = host
            dataPort = UInt16(numbers[4] * 256 + numbers[5])
        }
        guard let dataPort else { throw Failure.badReply("no passive port") }
        let data = NWConnection(host: NWEndpoint.Host(dataHost), port: NWEndpoint.Port(rawValue: dataPort)!, using: .tcp)
        try await Self.ready(data, timeout: timeout)
        return data
    }
}

/// Fails with `FTPControl.Failure.timeout` when `body` takes longer than `seconds`. The body is
/// raced rather than grouped: a task group would wait for the slow side to finish, and a socket
/// that never answers never does. `onTimeout` should make it finish (cancel the connection).
func withTimeout<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void = {}, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = TimeoutGate()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let work = Task {
            do { let value = try await body(); gate.run { cont.resume(returning: value) } }
            catch { gate.run { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            gate.run { cont.resume(throwing: FTPControl.Failure.timeout); onTimeout(); work.cancel() }
        }
    }
}

/// Lets exactly one of several racing callbacks run its body (resume a continuation, say).
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
private typealias TimeoutGate = OnceGate

// MARK: - Listing formats

/// Parsers for the two listing formats: MLSD facts (RFC 3659) and the classic LIST output, in its
/// Unix `ls -l` and Windows/IIS shapes.
public enum FTPListing {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public var size: Int64?
        public var modified: Date?
        public init(name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
            self.name = name; self.isDirectory = isDirectory; self.size = size; self.modified = modified
        }
    }

    /// "type=dir;modify=20240101120000;size=4096; Films"
    public static func parseMLSD(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let facts = line[..<space].split(separator: ";")
            let name = String(line[line.index(after: space)...])
            var type = "file", size: Int64?, modified: Date?
            for fact in facts {
                let pair = fact.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0].lowercased() {
                case "type": type = pair[1].lowercased()
                case "size": size = Int64(pair[1])
                case "modify": modified = date(fromMLSD: String(pair[1]))
                default: break
                }
            }
            if type == "cdir" || type == "pdir" { return nil }
            return Entry(name: name, isDirectory: type == "dir", size: type == "dir" ? nil : size, modified: modified)
        }
    }

    /// Unix: "-rw-r--r--   1 user group 12345 Jan 01 12:00 name" (or "Jan 01  2023"); Windows: "01-01-24  12:00PM  <DIR>  name".
    public static func parseLIST(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            if let unix = parseUnixLine(line) { return unix }
            if let win = parseWindowsLine(line) { return win }
            return nil
        }
    }

    private static let unixPattern = try! NSRegularExpression(pattern: #"^([\-dlbcps])[rwxsStT\-]{9}\+?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{4}|\d{1,2}:\d{2})\s+(.+)$"#)
    private static let windowsPattern = try! NSRegularExpression(pattern: #"^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})(AM|PM)\s+(<DIR>|\d+)\s+(.+)$"#)

    private static func parseUnixLine(_ line: String) -> Entry? {
        guard let m = unixPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String { String(line[Range(m.range(at: i), in: line)!]) }
        let kind = group(1)
        var name = group(6)
        if kind == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        let size = Int64(group(2))
        let modified = unixDate(month: group(3), day: group(4), yearOrTime: group(5))
        return Entry(name: name, isDirectory: kind == "d", size: kind == "d" ? nil : size, modified: modified)
    }

    private static func parseWindowsLine(_ line: String) -> Entry? {
        guard let m = windowsPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String { String(line[Range(m.range(at: i), in: line)!]) }
        let isDir = group(7) == "<DIR>"
        var comps = DateComponents()
        comps.month = Int(group(1)); comps.day = Int(group(2))
        let y = Int(group(3)) ?? 0; comps.year = y < 100 ? 2000 + y : y
        var hour = Int(group(4)) ?? 0
        if group(6) == "PM", hour < 12 { hour += 12 }
        if group(6) == "AM", hour == 12 { hour = 0 }
        comps.hour = hour; comps.minute = Int(group(5))
        return Entry(name: group(8), isDirectory: isDir, size: isDir ? nil : Int64(group(7)), modified: utc.date(from: comps))
    }

    private static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    private static func unixDate(month: String, day: String, yearOrTime: String) -> Date? {
        guard let m = months[month.lowercased()], let d = Int(day) else { return nil }
        var comps = DateComponents(month: m, day: d)
        if yearOrTime.contains(":") {
            // Within the last year: the year is this one, or last if the date would be in the future.
            let now = Date()
            let year = utc.component(.year, from: now)
            comps.year = year
            let parts = yearOrTime.split(separator: ":")
            comps.hour = Int(parts[0]); comps.minute = Int(parts[1])
            if let date = utc.date(from: comps), date > now.addingTimeInterval(24 * 3600) { comps.year = year - 1 }
        } else {
            comps.year = Int(yearOrTime)
        }
        return utc.date(from: comps)
    }

    /// "20240101120000" (optionally with fractional seconds) → a UTC date.
    public static func date(fromMLSD value: String) -> Date? {
        let digits = String(value.prefix(14))
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func n(_ a: Int, _ b: Int) -> Int { Int(digits[digits.index(digits.startIndex, offsetBy: a)..<digits.index(digits.startIndex, offsetBy: b)])! }
        return utc.date(from: DateComponents(year: n(0, 4), month: n(4, 6), day: n(6, 8), hour: n(8, 10), minute: n(10, 12), second: n(12, 14)))
    }
}
#endif
