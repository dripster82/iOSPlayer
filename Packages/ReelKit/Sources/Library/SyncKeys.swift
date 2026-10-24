import Foundation

/// CloudKit record names for synced library rows. Shared by the store (which announces deletions)
/// and the sync engine (which builds and applies records), so both sides agree on the names.
/// Record names are capped at 255 characters, so file names are hashed.
public enum SyncKeys {
    public static func source(_ id: UUID) -> String { "source|\(id.uuidString)" }
    public static func item(_ itemKey: String) -> String { "item|\(itemKey)" }
    public static func file(sourceID: UUID, relativePath: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (sourceID.uuidString + "|" + relativePath).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "file|" + String(h, radix: 16)
    }
}

/// How the store tells the sync engine about local writes without depending on it.
public struct SyncHooks {
    /// Something gained `pendingSync`; push soon.
    public var changed: () -> Void
    /// These record names were deleted locally; delete them in CloudKit.
    public var deleted: ([String]) -> Void
    public init(changed: @escaping () -> Void, deleted: @escaping ([String]) -> Void) {
        self.changed = changed
        self.deleted = deleted
    }
}
