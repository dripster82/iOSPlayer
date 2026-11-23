import Foundation

/// The server a stream comes from, as a host and a TCP port to knock on. The playback engine asks
/// whether it still answers when the network read behind a playing stream stands still, to tell a
/// dead session (the server answers: reconnect at once) from a server that has gone (play the
/// buffer and wait for it).
public enum StreamHost {
    private static let defaultPorts: [String: UInt16] = ["smb": 445, "ftp": 21, "ftps": 21, "sftp": 22, "http": 80, "https": 443, "dav": 80, "davs": 443, "webdav": 80, "webdavs": 443, "nfs": 2049]

    /// Nil for a local file, a stream served from this device (the loopback bridge) and a scheme
    /// with no known port: nothing to ask there.
    public static func target(for url: URL) -> (host: String, port: UInt16)? {
        guard !url.isFileURL, let host = url.host, !host.isEmpty, !["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) else { return nil }
        if let p = url.port { return UInt16(exactly: p).map { (host, $0) } }
        return defaultPorts[url.scheme?.lowercased() ?? ""].map { (host, $0) }
    }
}
