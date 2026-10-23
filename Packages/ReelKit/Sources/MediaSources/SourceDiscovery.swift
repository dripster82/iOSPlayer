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
}

/// Bonjour browsing for SMB (`_smb._tcp`) hosts. DLNA (SSDP) discovery lands with the DLNA source.
/// Requires the local-network privacy string and the Bonjour service list in Info.plist.
@MainActor
public final class SourceDiscovery: ObservableObject {
    @Published public private(set) var hosts: [DiscoveredHost] = []
    @Published public private(set) var isBrowsing = false
    private var browsers: [NWBrowser] = []

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
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
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
        let others = hosts.filter { $0.type != type }
        hosts = (others + found).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
