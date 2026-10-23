#if canImport(CloudKit) && canImport(SwiftData)
import Foundation
import CloudKit
import SwiftData
import MediaCore
import Library

/// CloudKit sync of watch state, favourites, overrides and collections via CKSyncEngine (iOS 17).
/// One private zone, "Library". Latest `updatedAt` wins; watched-flag rule from PLAN.md §10.4.
/// Source credentials and file paths are never synced.
@MainActor
public final class SyncEngine: NSObject, ObservableObject, CKSyncEngineDelegate {

    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isEnabled: Bool

    private let container: ModelContainer
    private var engine: CKSyncEngine?
    private let zoneID = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)
    private let stateKey = "reel.cksync.state"
    private let enabledKey = "reel.sync.enabled"

    public init(container: ModelContainer, cloudContainerID: String) {
        self.container = container
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        super.init()
        if isEnabled { start(cloudContainerID: cloudContainerID) }
    }

    public func setEnabled(_ on: Bool, cloudContainerID: String) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { start(cloudContainerID: cloudContainerID) } else { engine = nil }
    }

    private func start(cloudContainerID: String) {
        var serialization: CKSyncEngine.State.Serialization?
        if let data = UserDefaults.standard.data(forKey: stateKey) {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let config = CKSyncEngine.Configuration(database: CKContainer(identifier: cloudContainerID).privateCloudDatabase, stateSerialization: serialization, delegate: self)
        engine = CKSyncEngine(config)
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        pushPendingChanges()
    }

    /// Call after any local write that set `pendingSync`.
    public func pushPendingChanges() {
        guard let engine else { return }
        let ctx = container.mainContext
        var ids: [CKRecord.ID] = []
        for ws in (try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("watch", ws.itemKey)) }
        for f in (try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("fav", f.itemKey)) }
        for o in (try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("override", o.fileKey)) }
        for c in (try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("collection", c.id.uuidString)) }
        guard !ids.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    }

    public func fetchNow() async {
        do { try await engine?.fetchChanges() } catch { lastError = error.localizedDescription }
    }

    // MARK: - CKSyncEngineDelegate

    nonisolated public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.handle(event) }
    }

    nonisolated public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.record(for: id) }
        }
    }

    private func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) { UserDefaults.standard.set(data, forKey: stateKey) }
        case .accountChange(let e):
            switch e.changeType {
            case .signOut, .switchAccounts: UserDefaults.standard.removeObject(forKey: stateKey)
            default: break
            }
        case .fetchedRecordZoneChanges(let e):
            for mod in e.modifications { apply(mod.record) }
            for del in e.deletions { applyDeletion(del.recordID) }
            try? container.mainContext.save()
            lastSyncedAt = Date()
        case .sentRecordZoneChanges(let e):
            for saved in e.savedRecords { clearPending(saved.recordID) }
            for failed in e.failedRecordSaves { lastError = failed.error.localizedDescription }
            try? container.mainContext.save()
            lastSyncedAt = Date()
        case .fetchedDatabaseChanges, .sentDatabaseChanges, .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default: break
        }
    }

    // MARK: - Record mapping

    private func recordID(_ type: String, _ key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type)|\(key)", zoneID: zoneID)
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        let parts = id.recordName.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let ctx = container.mainContext
        switch parts[0] {
        case "watch":
            let key = parts[1]
            guard let ws = try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first else { return nil }
            let r = CKRecord(recordType: "WatchState", recordID: id)
            r["itemKey"] = ws.itemKey; r["watched"] = ws.watched ? 1 : 0; r["position"] = ws.position; r["duration"] = ws.duration
            r["updatedAt"] = ws.updatedAt; r["deviceID"] = ws.deviceID; r["lastPlayedAt"] = ws.lastPlayedAt
            return r
        case "fav":
            let key = parts[1]
            guard let f = try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first else { return nil }
            let r = CKRecord(recordType: "Favourite", recordID: id)
            r["itemKey"] = f.itemKey; r["createdAt"] = f.createdAt; r["deletedAt"] = f.deletedAt; r["updatedAt"] = f.updatedAt
            return r
        case "override":
            let key = parts[1]
            guard let o = try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first else { return nil }
            let r = CKRecord(recordType: "ItemOverride", recordID: id)
            r["fileKey"] = o.fileKey; r["forcedTMDbID"] = o.forcedTMDbID; r["forcedKind"] = o.forcedKindRaw; r["hidden"] = o.hidden ? 1 : 0; r["updatedAt"] = o.updatedAt
            return r
        case "collection":
            guard let uuid = UUID(uuidString: parts[1]), let c = try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first else { return nil }
            let r = CKRecord(recordType: "Collection", recordID: id)
            r["name"] = c.name; r["itemKeys"] = c.itemKeys; r["updatedAt"] = c.updatedAt
            return r
        default: return nil
        }
    }

    private func apply(_ r: CKRecord) {
        let ctx = container.mainContext
        let remoteUpdated = (r["updatedAt"] as? Date) ?? .distantPast
        switch r.recordType {
        case "WatchState":
            guard let key = r["itemKey"] as? String else { return }
            let ws = (try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first) ?? { let w = WatchState(itemKey: key, deviceID: "remote"); ctx.insert(w); return w }()
            guard remoteUpdated > ws.updatedAt else { return }
            ws.watched = ((r["watched"] as? Int) ?? 0) == 1
            ws.position = (r["position"] as? Double) ?? ws.position
            ws.duration = (r["duration"] as? Double) ?? ws.duration
            ws.lastPlayedAt = r["lastPlayedAt"] as? Date
            ws.deviceID = (r["deviceID"] as? String) ?? ws.deviceID
            ws.updatedAt = remoteUpdated; ws.pendingSync = false
        case "Favourite":
            guard let key = r["itemKey"] as? String else { return }
            let f = (try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first) ?? { let x = Favourite(itemKey: key); ctx.insert(x); return x }()
            guard remoteUpdated > f.updatedAt else { return }
            f.createdAt = (r["createdAt"] as? Date) ?? f.createdAt
            f.deletedAt = r["deletedAt"] as? Date
            f.updatedAt = remoteUpdated; f.pendingSync = false
        case "ItemOverride":
            guard let key = r["fileKey"] as? String else { return }
            let o = (try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first) ?? { let x = ItemOverride(fileKey: key); ctx.insert(x); return x }()
            guard remoteUpdated > o.updatedAt else { return }
            o.forcedTMDbID = r["forcedTMDbID"] as? Int
            o.forcedKindRaw = r["forcedKind"] as? String
            o.hidden = ((r["hidden"] as? Int) ?? 0) == 1
            o.updatedAt = remoteUpdated; o.pendingSync = false
        case "Collection":
            let name = r.recordID.recordName.split(separator: "|", maxSplits: 1).map(String.init)
            guard name.count == 2, let uuid = UUID(uuidString: name[1]) else { return }
            let c = (try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first) ?? { let x = MediaCollection(name: ""); x.id = uuid; ctx.insert(x); return x }()
            guard remoteUpdated > c.updatedAt else { return }
            c.name = (r["name"] as? String) ?? c.name
            c.itemKeys = (r["itemKeys"] as? [String]) ?? c.itemKeys
            c.updatedAt = remoteUpdated; c.pendingSync = false
        default: break
        }
    }

    private func applyDeletion(_ id: CKRecord.ID) {
        let parts = id.recordName.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "collection", let uuid = UUID(uuidString: parts[1]) else { return }
        let ctx = container.mainContext
        if let c = try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first { ctx.delete(c) }
    }

    private func clearPending(_ id: CKRecord.ID) {
        let parts = id.recordName.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let ctx = container.mainContext
        let key = parts[1]
        switch parts[0] {
        case "watch": if let x = try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first { x.pendingSync = false }
        case "fav": if let x = try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first { x.pendingSync = false }
        case "override": if let x = try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first { x.pendingSync = false }
        case "collection": if let uuid = UUID(uuidString: key), let x = try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first { x.pendingSync = false }
        default: break
        }
    }
}
#endif
