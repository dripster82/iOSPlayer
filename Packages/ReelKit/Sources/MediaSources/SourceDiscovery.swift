#if canImport(Network)
import Foundation
import Network
import MediaCore

/// A host found on the LAN, before the user has given it credentials.
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public var id: String { "\(type.rawValue)-\(host)" }
    public var name: String
    public var host: String
    public var type: SourceType
    /// Something the form can prefill: a DLNA description URL, or a WebDAV port.
    public var path: String = ""
    public var port: Int? = nil
}

/// Two ways of finding servers: Bonjour, for hosts that announce themselves (SMB, WebDAV), and a
/// sweep of the local subnet that knocks on each address's SMB, FTP, SFTP, NFS, WebDAV and DLNA
/// ports, for the many NAS boxes that announce nothing. A multicast SSDP search would need an
/// entitlement Apple grants case by case, so DLNA servers get a unicast search each instead.
/// Requires the local-network privacy string and the Bonjour service list in Info.plist.
@MainActor
public final class SourceDiscovery: ObservableObject {
    @Published public private(set) var hosts: [DiscoveredHost] = []
    @Published public private(set) var isBrowsing = false
    /// What the sweep is doing, for the screen ("Checking 192.168.1.0/24…"), nil when idle.
    @Published public private(set) var sweepStatus: String?
    private var browsers: [NWBrowser] = []
    private var sweep: Task<Void, Never>?

    public init() {}

    public func start() {
        stop()
        isBrowsing = true
        for (service, type) in [("_smb._tcp", SourceType.smb), ("_webdav._tcp", .webdav), ("_webdavs._tcp", .webdav)] {
            let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.merge(results, type: type) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        sweepSubnet()
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        sweep?.cancel(); sweep = nil
        sweepStatus = nil
        isBrowsing = false
    }

    private func merge(_ results: Set<NWBrowser.Result>, type: SourceType) {
        var found: [DiscoveredHost] = []
        for r in results {
            if case .service(let name, _, _, _) = r.endpoint {
                // Bonjour names resolve via mDNS; `name.local` is what AMSMB2 and VLC accept.
                found.append(DiscoveredHost(name: name, host: name.replacingOccurrences(of: " ", with: "-") + ".local", type: type))
            }
        }
        for h in found { add(h) }
    }

    /// Keeps one entry per (type, host); a Bonjour name beats an address, a swept address never
    /// displaces a named one for the same server.
    private func add(_ h: DiscoveredHost) {
        if hosts.contains(where: { $0.id == h.id }) { return }
        if hosts.contains(where: { $0.type == h.type && $0.name == h.name && !h.name.isEmpty }) { return }
        hosts.append(h)
        hosts.sort { ($0.name.lowercased(), $0.type.rawValue) < ($1.name.lowercased(), $1.type.rawValue) }
    }

    // MARK: - Subnet sweep

    /// Probes every address of the Wi-Fi interface's subnet (capped at a /24) for the ports the
    /// supported servers listen on, and asks each DLNA candidate for its description.
    public func sweepSubnet() {
        sweep?.cancel()
        guard let (address, prefix) = Self.wifiNetwork() else { sweepStatus = nil; return }
        let addresses = Self.addresses(in: address, prefix: max(prefix, 24))
        sweepStatus = "Checking \(Self.describe(address, prefix: max(prefix, 24))) for servers…"
        sweep = Task { [weak self] in
            await withTaskGroup(of: [DiscoveredHost].self) { group in
                var pending = addresses[...]
                var running = 0
                func launch(_ ip: String) { group.addTask { await Self.probe(ip) } }
                while running < 96, let ip = pending.popFirst() { launch(ip); running += 1 }
                for await found in group {
                    guard !Task.isCancelled else { break }
                    for h in found { await MainActor.run { self?.add(h) } }
                    if let ip = pending.popFirst() { launch(ip) }
                }
            }
            await MainActor.run { self?.sweepStatus = nil }
        }
    }

    /// One address: TCP ports for the file protocols, a unicast SSDP search for DLNA.
    nonisolated private static func probe(_ ip: String) async -> [DiscoveredHost] {
        var found: [DiscoveredHost] = []
        let ports: [(UInt16, SourceType)] = [(445, .smb), (21, .ftp), (22, .sftp), (2049, .nfs)]
        var open: [SourceType] = []
        await withTaskGroup(of: SourceType?.self) { group in
            for (port, type) in ports { group.addTask { await tcpOpen(ip, port) ? type : nil } }
            group.addTask {   // Synology's WebDAV ports
                if await tcpOpen(ip, 5005) { return .webdav }
                return await tcpOpen(ip, 5006) ? .webdav : nil
            }
            for await t in group { if let t { open.append(t) } }
        }
        let name = open.isEmpty ? ip : (await reverseName(ip) ?? ip)
        for type in open {
            let port: Int? = type == .webdav ? 5005 : nil
            found.append(DiscoveredHost(name: name, host: ip, type: type, port: port))
        }
        if let (location, friendly) = await dlnaSearch(ip) {
            found.append(DiscoveredHost(name: friendly ?? name, host: ip, type: .dlna, path: location.absoluteString))
        }
        return found
    }

    nonisolated private static func tcpOpen(_ ip: String, _ port: UInt16) async -> Bool {
        let c = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { c.cancel() }
        return (try? await FTPControl.ready(c, timeout: 1.2)) != nil
    }

    /// LOCATION and friendlyName of a media server answering a unicast M-SEARCH on this address.
    nonisolated private static func dlnaSearch(_ ip: String) async -> (URL, String?)? {
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
        let c = NWConnection(host: NWEndpoint.Host(ip), port: 1900, using: .udp)
        defer { c.cancel() }
        guard (try? await FTPControl.ready(c, timeout: 1)) != nil else { return nil }
        c.send(content: Data(request.utf8), completion: .idempotent)
        guard let (data, _) = try? await FTPControl.receive(c, timeout: 1.5), let location = SSDP.location(in: String(decoding: data, as: UTF8.self)) else { return nil }
        var request2 = URLRequest(url: location); request2.timeoutInterval = 3
        let friendly = (try? await URLSession.shared.data(for: request2)).flatMap { DeviceDescription.parse($0.0, base: location)?.friendlyName }
        return (location, friendly?.isEmpty == false ? friendly : nil)
    }

    nonisolated private static func reverseName(_ ip: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr(ip)
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD) } } == 0
                let name = ok ? String(cString: buffer) : nil
                cont.resume(returning: name.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 })
            }
        }
    }

    // MARK: Addresses

    /// The Wi-Fi interface's IPv4 address and prefix length.
    nonisolated static func wifiNetwork() -> (String, Int)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var fallback: (String, Int)?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ptr.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            var prefix = 24
            if let mask = ptr.pointee.ifa_netmask {
                let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                prefix = m.nonzeroBitCount
            }
            if name == "en0" { return (ip, prefix) }
            if fallback == nil, name.hasPrefix("en") { fallback = (ip, prefix) }
        }
        return fallback
    }

    /// Every usable address in the network, the device's own excluded.
    nonisolated static func addresses(in address: String, prefix: Int) -> [String] {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, prefix >= 8, prefix <= 30 else { return [] }
        let ip = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        let mask: UInt32 = ~UInt32(0) << UInt32(32 - prefix)
        let network = ip & mask
        let broadcast = network | ~mask
        return ((network + 1)..<broadcast).filter { $0 != ip }.map { "\($0 >> 24).\(($0 >> 16) & 255).\(($0 >> 8) & 255).\($0 & 255)" }
    }

    nonisolated static func describe(_ address: String, prefix: Int) -> String {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return address }
        let ip = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        let network = ip & (~UInt32(0) << UInt32(32 - prefix))
        return "\(network >> 24).\((network >> 16) & 255).\((network >> 8) & 255).\(network & 255)/\(prefix)"
    }
}
#endif
