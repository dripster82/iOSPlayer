import Foundation
import Network

/// Wake-on-LAN: a UDP "magic packet" (6 × 0xFF then the MAC address 16 times) broadcast on the local
/// network. A NAS that has spun down or gone to sleep answers nothing for 30 to 90 s after it; the
/// caller keeps retrying its connection for that long (see `LibraryStore.playbackURL`).
public enum WakeOnLAN {
    public enum WakeError: Error, LocalizedError {
        case badAddress
        public var errorDescription: String? { "That isn't a MAC address. Expected six pairs like A1:B2:C3:D4:E5:F6." }
    }

    /// Accepts "A1:B2:C3:D4:E5:F6", "a1-b2-c3-d4-e5-f6" or "a1b2c3d4e5f6"; returns the six bytes.
    public static func parse(_ mac: String) -> [UInt8]? {
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return bytes
    }

    public static func normalise(_ mac: String) -> String? {
        parse(mac).map { $0.map { String(format: "%02X", $0) }.joined(separator: ":") }
    }

    /// Sends the packet to the limited broadcast address on ports 9 and 7. Returns once sent; whether the
    /// machine wakes is only knowable by trying to connect to it afterwards.
    public static func wake(mac: String) async throws {
        guard let bytes = parse(mac) else { throw WakeError.badAddress }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        for port: NWEndpoint.Port in [9, 7] {
            await send(packet, to: port)
        }
    }

    private static func send(_ packet: Data, to port: NWEndpoint.Port) async {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(host: "255.255.255.255", port: port, using: params)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            func finish() { if !finished { finished = true; connection.cancel(); done.resume() } }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { _ in finish() })
                case .failed, .cancelled: finish()
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish() }
        }
    }
}
