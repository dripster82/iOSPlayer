import Foundation
#if canImport(KeychainAccess)
import KeychainAccess
#endif

/// Source passwords live in the Keychain, keyed by source ID. They are never written to
/// SwiftData or CloudKit (PLAN.md §10.4); they travel between the user's own devices through
/// iCloud Keychain (`synchronizable`), which is end-to-end encrypted and never visible to the app's
/// CloudKit container.
public struct CredentialStore: Sendable {
    public static let shared = CredentialStore()
    private let service = "uk.co.ketelle.reel.sources"

    public init() {}

    public func save(_ credentials: Credentials, for sourceID: UUID) throws {
        #if canImport(KeychainAccess)
        let kc = Keychain(service: service).accessibility(.afterFirstUnlock).synchronizable(true)
        try kc.set(credentials.password, key: key(sourceID, "password"))
        try kc.set(credentials.username, key: key(sourceID, "username"))
        #else
        InMemoryVault.shared.store[sourceID] = credentials
        #endif
    }

    public func load(for sourceID: UUID) -> Credentials? {
        #if canImport(KeychainAccess)
        let kc = Keychain(service: service).synchronizable(true)
        guard let user = try? kc.get(key(sourceID, "username")), let pass = try? kc.get(key(sourceID, "password")) else { return nil }
        return Credentials(username: user, password: pass)
        #else
        return InMemoryVault.shared.store[sourceID]
        #endif
    }

    public func remove(for sourceID: UUID) {
        #if canImport(KeychainAccess)
        let kc = Keychain(service: service).synchronizable(true)
        try? kc.remove(key(sourceID, "username"))
        try? kc.remove(key(sourceID, "password"))
        #else
        InMemoryVault.shared.store[sourceID] = nil
        #endif
    }

    private func key(_ id: UUID, _ field: String) -> String { "\(id.uuidString).\(field)" }
}

#if !canImport(KeychainAccess)
/// Non-Apple fallback for tests and tooling only.
final class InMemoryVault: @unchecked Sendable {
    static let shared = InMemoryVault()
    var store: [UUID: Credentials] = [:]
}
#endif
