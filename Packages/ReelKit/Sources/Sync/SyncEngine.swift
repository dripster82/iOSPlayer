#if canImport(CloudKit) && canImport(SwiftData)
import Foundation
import CloudKit
import SwiftData
import MediaCore
import MediaSources
import Library

/// CloudKit sync via CKSyncEngine (iOS 17). One private zone, "Library". Latest `updatedAt` wins.
///
/// What syncs (PLAN.md §10, revised 24 Oct 2026):
/// - watch state, favourites, overrides, collections (the original set);
/// - sources (everything except the password, which travels through iCloud Keychain);
/// - the scanned library itself: items and files, keyed deterministically so two devices scanning
///   the same share converge on the same records instead of duplicating them.
/// Files-app (local) sources are device-specific and stay local.
/// How a restore (the first fetch after sync is turned on) is going, for the restore screen. The
/// totals come from the Summary record the other device keeps up to date; until it has arrived
/// only the counts are known.
public struct RestoreProgress: Equatable, Sendable {
    public var sources = 0
    public var items = 0
    public var files = 0
    public var expectedItems: Int?
    public var expectedFiles: Int?
    public var startedAt = Date()
    public var fraction: Double? {
        guard let ei = expectedItems, let ef = expectedFiles, ei + ef > 0 else { return nil }
        return min(1, Double(items + files) / Double(ei + ef))
    }
}

/// What applying one fetched batch produced, from the background context back to the engine.
struct AppliedBatch: Sendable {
    var toDelete: [String] = []
    var sources = 0, items = 0, files = 0
    var expectedItems: Int?, expectedFiles: Int?
    var changed: Bool { sources + items + files > 0 }
}

@MainActor
public final class SyncEngine: NSObject, ObservableObject, CKSyncEngineDelegate {
    /// Non-nil while a restore is running; the app shows a progress screen instead of the library so
    /// nothing appears before its files have arrived and been linked.
    @Published public private(set) var restore: RestoreProgress?
    /// The viewer chose to carry on in the background: Home shows a banner instead, with a way back.
    @Published public private(set) var restoreHidden = false

    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var lastError: String? { didSet { if let e = lastError { Self.log(e) } } }
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isSyncing = false
    /// Set by the app: called after remote changes were applied, so the store drops its caches and views refresh.
    public var onChangesApplied: (() -> Void)?
    @Published public private(set) var lastSummary: String?

    /// Last few errors, persisted so they can be read off a device (Preferences plist).
    private static func log(_ message: String) {
        Diagnostics.log("sync", message)
        var entries = UserDefaults.standard.stringArray(forKey: "reel.sync.errorLog") ?? []
        entries.append("\(Date().formatted(.iso8601)) \(message)")
        UserDefaults.standard.set(Array(entries.suffix(10)), forKey: "reel.sync.errorLog")
    }

    /// CloudKit's localizedDescription is "Failed to send changes" for a dozen different causes. This
    /// names the CKError code, any retry-after, and for a partial failure the first few records that
    /// were refused and why, so the Settings and Diagnostics screens say something actionable.
    static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else {
            let ns = error as NSError
            return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
        var parts = [codeName(ck.code)]
        if let retry = ck.retryAfterSeconds { parts.append("retry in \(Int(retry))s") }
        if ck.code == .partialFailure, let per = ck.partialErrorsByItemID {
            let items = per.prefix(3).map { key, value -> String in
                let name = (key as? CKRecord.ID)?.recordName ?? "\(key)"
                let inner = (value as? CKError).map { codeName($0.code) } ?? value.localizedDescription
                return "\(name.prefix(40)): \(inner)"
            }
            parts.append("\(per.count) records; " + items.joined(separator: "; "))
        } else if ck.code != .partialFailure {
            parts.append(ck.localizedDescription)
        }
        return parts.joined(separator: " · ")
    }

    private static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .networkUnavailable: "no network"
        case .networkFailure: "network failure"
        case .serviceUnavailable: "iCloud unavailable"
        case .requestRateLimited: "rate limited"
        case .notAuthenticated: "not signed in to iCloud"
        case .permissionFailure: "no permission"
        case .quotaExceeded: "iCloud storage full"
        case .limitExceeded: "request too large"
        case .zoneNotFound: "zone missing"
        case .userDeletedZone: "zone deleted by user"
        case .serverRecordChanged: "record changed on server"
        case .unknownItem: "record missing on server"
        case .invalidArguments: "invalid record"
        case .serverRejectedRequest: "rejected by server"
        case .accountTemporarilyUnavailable: "iCloud account temporarily unavailable"
        case .partialFailure: "some records failed"
        case .internalError: "CloudKit internal error"
        case .zoneBusy: "zone busy"
        case .changeTokenExpired: "change token expired"
        case .batchRequestFailed: "batch failed"
        case .constraintViolation: "constraint violation"
        case .assetFileNotFound: "asset file missing"
        case .incompatibleVersion: "incompatible version"
        case .managedAccountRestricted: "managed account restricted"
        case .participantMayNeedVerification: "participant needs verification"
        default: "CKError \(code.rawValue)"
        }
    }

    /// Rows still waiting to upload, for the Settings screen.
    public var pendingCount: Int {
        let d1 = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.pendingSync })
        let d2 = FetchDescriptor<MediaFile>(predicate: #Predicate { $0.pendingSync })
        let d3 = FetchDescriptor<WatchState>(predicate: #Predicate { $0.pendingSync })
        let d4 = FetchDescriptor<Favourite>(predicate: #Predicate { $0.pendingSync })
        return ((try? ctx.fetchCount(d1)) ?? 0) + ((try? ctx.fetchCount(d2)) ?? 0) + ((try? ctx.fetchCount(d3)) ?? 0) + ((try? ctx.fetchCount(d4)) ?? 0)
    }

    /// Settings → Sync now: fetch, push, and say what happened.
    public func syncNow() async {
        guard engine != nil else { lastSummary = "Sync is off."; return }
        isSyncing = true
        lastError = nil
        pushPendingChanges()
        do {
            try await engine?.fetchChanges()
            try await engine?.sendChanges()
            let left = pendingCount
            lastSummary = left == 0 ? "Up to date." : "\(left) changes still uploading in the background."
        } catch {
            lastError = Self.describe(error)
            lastSummary = "Sync failed."
        }
        isSyncing = false
    }

    private let container: ModelContainer
    /// Background context for fetched changes; see `handleEvent`.
    private let applier: SyncApplier
    private var engine: CKSyncEngine?
    private let zoneID = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)
    private let stateKey = "reel.cksync.state"
    private let enabledKey = "reel.sync.enabled"
    private var ctx: ModelContext { container.mainContext }

    public init(container: ModelContainer, cloudContainerID: String) {
        self.container = container
        applier = SyncApplier(modelContainer: container)
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        super.init()
        if isEnabled { start(cloudContainerID: cloudContainerID) }
    }

    public func setEnabled(_ on: Bool, cloudContainerID: String) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { start(cloudContainerID: cloudContainerID); markEverythingPending(); pushPendingChanges() } else { engine = nil }
    }

    /// `CKContainer(identifier:)` raises an Objective-C exception, uncatchable from Swift, when the app
    /// is signed without that container. A build signed with the keychain-only entitlements (or a
    /// gutted entitlements file) must not take the whole app down at launch, so check the embedded
    /// provisioning profile first.
    public static func buildSupportsCloudKit(containerID: String) -> Bool {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: Data(containerID.utf8)) != nil
    }

    private func start(cloudContainerID: String) {
        guard Self.buildSupportsCloudKit(containerID: cloudContainerID) else {
            lastError = "This build isn't signed for iCloud (\(cloudContainerID)). Sync is off until it is."
            engine = nil
            return
        }
        // One-time full refetch after the source-convergence upgrade: Source records fetched by an older
        // build were ignored, and CloudKit will not resend them without starting from a fresh state.
        let refetchKey = "reel.sync.refetch.v4"   // v4: collect change tags for every record
        if !UserDefaults.standard.bool(forKey: refetchKey) {
            UserDefaults.standard.removeObject(forKey: stateKey)
            UserDefaults.standard.set(true, forKey: refetchKey)
        }
        var serialization: CKSyncEngine.State.Serialization?
        if let data = UserDefaults.standard.data(forKey: stateKey) {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let config = CKSyncEngine.Configuration(database: CKContainer(identifier: cloudContainerID).privateCloudDatabase, stateSerialization: serialization, delegate: self)
        engine = CKSyncEngine(config)
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        Self.dedupeSources(in: ctx)
        // Devices that enabled sync before library sync existed have a library that never went up.
        let backfillKey = "reel.sync.libraryBackfill.v1"
        if !UserDefaults.standard.bool(forKey: backfillKey) {
            markEverythingPending()
            UserDefaults.standard.set(true, forKey: backfillKey)
        }
        // Updates sent before change tags were kept were rejected and their pending flag cleared; send the
        // small, important rows again once so the newest progress and favourites reach the server.
        let resendKey = "reel.sync.resendState.v1"
        if !UserDefaults.standard.bool(forKey: resendKey) {
            for w in (try? ctx.fetch(FetchDescriptor<WatchState>())) ?? [] { w.pendingSync = true }
            for f in (try? ctx.fetch(FetchDescriptor<Favourite>())) ?? [] { f.pendingSync = true }
            for o in (try? ctx.fetch(FetchDescriptor<ItemOverride>())) ?? [] { o.pendingSync = true }
            for c in (try? ctx.fetch(FetchDescriptor<MediaCollection>())) ?? [] { c.pendingSync = true }
            try? ctx.save()
            UserDefaults.standard.set(true, forKey: resendKey)
        }
        pushPendingChanges()
        sendSummary(onlyIfMissing: true)
    }

    /// The totals a restoring device shows a percentage against. Sent with any library change, and on
    /// start only when iCloud has no Summary yet (none seen fetched or saved). A device whose library
    /// is empty (one mid-restore) keeps quiet so it never overwrites the real totals with zeros.
    private func sendSummary(onlyIfMissing: Bool = false) {
        guard let engine, ((try? ctx.fetchCount(FetchDescriptor<MediaItem>())) ?? 0) > 0 else { return }
        if onlyIfMissing {
            let name = Self.summaryName
            let seen = ((try? ctx.fetchCount(FetchDescriptor<SyncRecordMeta>(predicate: #Predicate { $0.recordName == name }))) ?? 0) > 0
            if seen { return }
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(Self.summaryName))])
    }

    /// Two devices that each added the same share before sync existed hold it under different ids. The
    /// remote copy is recognised by type + host + share and never instantiated locally; this also removes
    /// any duplicate that slipped in earlier (locally only: the other device keeps its own record).
    nonisolated static func dedupeSources(in ctx: ModelContext) {
        let all = (try? ctx.fetch(FetchDescriptor<SourceRecord>())) ?? []
        var seen: [String: SourceRecord] = [:]
        for s in all.sorted(by: { $0.files.count > $1.files.count }) {
            let key = Self.identity(type: s.type, host: s.host, path: s.path)
            if seen[key] != nil, s.type != .local { ctx.delete(s) } else { seen[key] = s }
        }
        try? ctx.save()
    }

    /// Moves a local source (and its files) to the id the other device uses. The files' old CloudKit
    /// records are deleted and they are re-uploaded under names derived from the new id.
    nonisolated static func rekey(_ source: SourceRecord, to newID: UUID, in ctx: ModelContext, deleting: inout [String]) -> SourceRecord {
        let oldID = source.id
        if let creds = CredentialStore.shared.load(for: oldID) {
            try? CredentialStore.shared.save(creds, for: newID)
            CredentialStore.shared.remove(for: oldID)
        }
        var oldNames = [SyncKeys.source(oldID)]
        for f in source.files {
            if let old = f.syncKey { oldNames.append(old) }
            f.syncKey = nil
            f.pendingSync = true
            // updatedAt is deliberately left alone: the other device's copy of the same file may be newer,
            // and the save conflict that follows must let the genuinely newer state win.
        }
        source.id = newID
        source.pendingSync = false
        try? ctx.save()
        deleting += oldNames
        return source
    }

    nonisolated private static func identity(type: SourceType, host: String, path: String) -> String {
        "\(type.rawValue)|\(host.trimmingCharacters(in: .whitespaces).lowercased())|\(path.trimmingCharacters(in: CharacterSet(charactersIn: " /")).lowercased())"
    }

    /// First enable on a device with an existing library: everything it has should go up.
    private func markEverythingPending() {
        for s in (try? ctx.fetch(FetchDescriptor<SourceRecord>())) ?? [] where s.type != .local { s.pendingSync = true }
        for i in (try? ctx.fetch(FetchDescriptor<MediaItem>())) ?? [] { i.pendingSync = true }
        for f in (try? ctx.fetch(FetchDescriptor<MediaFile>())) ?? [] where f.source?.type != .local { f.pendingSync = true }
        try? ctx.save()
    }

    // MARK: - Pushing

    /// Call after any local write that set `pendingSync`. Cheap when nothing is pending.
    public func pushPendingChanges() {
        guard let engine else { return }
        var ids: [CKRecord.ID] = []
        for ws in (try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("watch|" + ws.itemKey)) }
        for f in (try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("fav|" + f.itemKey)) }
        for o in (try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("override|" + o.fileKey)) }
        for c in (try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID("collection|" + c.id.uuidString)) }
        for g in (try? ctx.fetch(FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID(SyncKeys.groupArt(g.groupID))) }
        for s in (try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.pendingSync }))) ?? [] where s.type != .local { ids.append(recordID(SyncKeys.source(s.id))) }
        let libraryChanged = ((try? ctx.fetchCount(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.pendingSync }))) ?? 0) > 0
            || ((try? ctx.fetchCount(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.pendingSync }))) ?? 0) > 0
        if libraryChanged { sendSummary() }   // totals, so a restoring device can show a percentage
        for i in (try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.pendingSync }))) ?? [] { ids.append(recordID(SyncKeys.item(i.itemKey))) }
        for f in (try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.pendingSync }))) ?? [] {
            guard let source = f.source, source.type != .local else { f.pendingSync = false; continue }
            let key = SyncKeys.file(sourceID: source.id, relativePath: f.relativePath)
            if f.syncKey != key { f.syncKey = key }
            ids.append(recordID(key))
        }
        try? ctx.save()
        guard !ids.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    }

    /// Local deletions (by record name) to mirror in CloudKit.
    public func deleteRecords(named names: [String]) {
        guard let engine, !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map { .deleteRecord(recordID($0)) })
    }

    /// Push whatever is pending and wait for CloudKit to accept it. Used on the way to the background,
    /// where the engine's own scheduling may not get a turn before the app is suspended.
    public func sendNow() async {
        pushPendingChanges()
        do { try await engine?.sendChanges() } catch { lastError = "Send failed: " + Self.describe(error) }
    }

    /// Whether this Apple ID already holds a Reel library: true when the private database has the
    /// "Library" zone, which only a device with sync on ever creates. Cheap (one zone listing), and
    /// safe to call with sync off: the first-run screen uses it to offer a restore before Add Source.
    /// False when the build is not signed for iCloud, no account is signed in, or iCloud is unreachable.
    public func cloudLibraryExists(cloudContainerID: String) async -> Bool {
        guard Self.buildSupportsCloudKit(containerID: cloudContainerID) else { return false }
        let container = CKContainer(identifier: cloudContainerID)
        guard (try? await container.accountStatus()) == .available else { return false }
        guard let zones = try? await container.privateCloudDatabase.allRecordZones() else { return false }
        return zones.contains { $0.zoneID.zoneName == zoneID.zoneName }
    }

    /// Turn sync on and run the first fetch as a restore: `restore` reports progress until the fetch
    /// completes (everything in iCloud is then local and linked) or fails, and clears itself after.
    public func beginRestore(cloudContainerID: String) {
        setEnabled(true, cloudContainerID: cloudContainerID)
        restore = RestoreProgress()
        restoreHidden = false
        isSyncing = true
        fetchSummaryDirectly(cloudContainerID: cloudContainerID)
        Task { @MainActor in
            await fetchNow()
            // Fetch is complete: the trailing refresh may still be pending, so refresh now.
            refreshTask?.cancel(); refreshTask = nil
            onChangesApplied?()
            isSyncing = false
            restore = nil
            restoreHidden = false
        }
    }

    /// The change stream delivers records in server order, and the Summary was written after every
    /// item and file, so waiting for it there means a percentage only at the very end. Fetch it by
    /// id instead, retrying for a while in case the other device has not sent it yet.
    private func fetchSummaryDirectly(cloudContainerID: String) {
        let db = CKContainer(identifier: cloudContainerID).privateCloudDatabase
        let id = CKRecord.ID(recordName: Self.summaryName, zoneID: zoneID)
        Task { @MainActor [weak self] in
            for attempt in 0..<10 {
                guard let self, self.restore != nil, self.restore?.expectedItems == nil else { return }
                if attempt > 0 { try? await Task.sleep(for: .seconds(15)) }
                guard let r = try? await db.record(for: id), var p = self.restore else { continue }
                p.expectedItems = r["itemCount"] as? Int
                p.expectedFiles = r["fileCount"] as? Int
                self.restore = p
                return
            }
        }
    }

    /// Carry on in the background: the library shows while the rest arrives.
    public func dismissRestore() { restoreHidden = true }
    public func showRestore() { restoreHidden = false }

    public func fetchNow() async {
        do { try await engine?.fetchChanges() } catch { lastError = "Fetch failed: " + Self.describe(error) }
    }

    // MARK: - CKSyncEngineDelegate

    nonisolated public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .fetchedRecordZoneChanges(let e) = event {
            // Applied on a background context: a restore of thousands of records must never stall the
            // UI. The main thread only learns that something changed, at most every couple of seconds.
            let mods = e.modifications.map(\.record), dels = e.deletions.map(\.recordID)
            let applied = await applier.apply(modifications: mods, deletions: dels)
            await MainActor.run { self.fetchedChangesApplied(applied, changed: !mods.isEmpty || !dels.isEmpty) }
            return
        }
        await MainActor.run { self.handle(event) }
    }

    private func fetchedChangesApplied(_ applied: AppliedBatch, changed: Bool) {
        lastSyncedAt = Date()
        deleteRecords(named: applied.toDelete)
        if var r = restore {
            r.sources += applied.sources; r.items += applied.items; r.files += applied.files
            if let n = applied.expectedItems { r.expectedItems = n }
            if let n = applied.expectedFiles { r.expectedFiles = n }
            restore = r
        }
        if changed { scheduleRefresh() }
    }

    /// Every screen rebuilds on `onChangesApplied`; during a restore batches arrive several times a
    /// second, so refreshes are coalesced to one every two seconds plus a trailing one.
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAt = Date.distantPast
    private func scheduleRefresh() {
        let since = Date().timeIntervalSince(lastRefreshAt)
        if since >= 2 { lastRefreshAt = Date(); onChangesApplied?(); return }
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, 2 - since)))
            guard let self else { return }
            self.refreshTask = nil
            self.lastRefreshAt = Date()
            self.onChangesApplied?()
        }
    }

    nonisolated public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        // Watch state, favourites, sources and deletions go first so a 10,000-record backfill never
        // delays "I paused on the iPad"; items before files; at most 200 per batch.
        func rank(_ change: CKSyncEngine.PendingRecordZoneChange) -> Int {
            switch change {
            case .deleteRecord: return 0
            case .saveRecord(let id):
                let type = id.recordName.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
                switch type { case "summary": return 0; case "watch", "fav", "override", "collection", "source": return 1; case "item": return 2; default: return 3 }
            @unknown default: return 4
            }
        }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }.sorted { rank($0) < rank($1) }.prefix(200)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(pending)) { id in
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
        case .fetchedRecordZoneChanges:
            break   // handled in handleEvent, off the main thread
        case .sentRecordZoneChanges(let e):
            for saved in e.savedRecords { Self.rememberSystemFields(saved, in: ctx); clearPending(saved.recordID) }
            for failed in e.failedRecordSaves {
                let id = failed.record.recordID
                if failed.error.code == .serverRecordChanged, let server = failed.error.serverRecord {
                    // Our save lacked the server's change tag, or someone else wrote first. Keep the
                    // server's tag; if their copy is newer take it, otherwise send ours again on top.
                    Self.rememberSystemFields(server, in: ctx)
                    let remote = (server["updatedAt"] as? Date) ?? .distantPast
                    if let local = localUpdatedAt(id), local > remote {
                        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    } else {
                        var toDelete: [String] = []
                        Self.apply(server, in: ctx, deleting: &toDelete); clearPending(id)
                        deleteRecords(named: toDelete)
                    }
                } else if failed.error.code == .unknownItem {
                    Self.forgetSystemFields(id, in: ctx)
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])   // stale tag for a record that is gone: recreate
                } else {
                    lastError = "\(failed.record.recordType) \(id.recordName.prefix(40)): " + Self.describe(failed.error)
                }
            }
            for (id, _) in e.failedRecordDeletes { Self.forgetSystemFields(id, in: ctx) }
            // A delete for something already gone is success as far as we are concerned.
            Self.reconcileLinks(in: ctx)
            try? ctx.save()
            lastSyncedAt = Date()
        case .didFetchRecordZoneChanges(let e):
            if let err = e.error { lastError = "Fetch failed: " + Self.describe(err) }
        case .sentDatabaseChanges(let e):
            for (_, err) in e.failedZoneSaves.map({ ($0.zone, $0.error) }) { lastError = "Zone save failed: " + Self.describe(err) }
        case .fetchedDatabaseChanges, .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges, .willFetchRecordZoneChanges:
            break
        @unknown default: break
        }
    }

    // MARK: - Record building

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    /// One record per library with the item and file counts, for restore progress on another device.
    nonisolated static let summaryName = "summary|library"

    /// CloudKit cannot type an empty list on first sight; an absent field reads back as [] anyway.
    private static func list(_ values: [String]) -> [String]? { values.isEmpty ? nil : values }

    nonisolated static func split(_ id: CKRecord.ID) -> (String, String)? {
        let parts = id.recordName.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    // MARK: - Change tags

    /// A record to fill in: the server's copy (with its change tag) when we have seen one, else a new one.
    private func baseRecord(_ type: String, _ id: CKRecord.ID) -> CKRecord {
        let name = id.recordName
        if let meta = try? ctx.fetch(FetchDescriptor<SyncRecordMeta>(predicate: #Predicate { $0.recordName == name })).first,
           let coder = try? NSKeyedUnarchiver(forReadingFrom: meta.systemFields) {
            coder.requiresSecureCoding = true
            if let r = CKRecord(coder: coder), r.recordType == type { return r }
        }
        return CKRecord(recordType: type, recordID: id)
    }

    nonisolated static func rememberSystemFields(_ r: CKRecord, in ctx: ModelContext) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        r.encodeSystemFields(with: coder)
        coder.finishEncoding()
        let name = r.recordID.recordName
        if let meta = try? ctx.fetch(FetchDescriptor<SyncRecordMeta>(predicate: #Predicate { $0.recordName == name })).first {
            meta.systemFields = coder.encodedData
        } else {
            ctx.insert(SyncRecordMeta(recordName: name, systemFields: coder.encodedData))
        }
    }

    nonisolated static func forgetSystemFields(_ id: CKRecord.ID, in ctx: ModelContext) {
        let name = id.recordName
        if let meta = try? ctx.fetch(FetchDescriptor<SyncRecordMeta>(predicate: #Predicate { $0.recordName == name })).first { ctx.delete(meta) }
    }

    /// The local row's `updatedAt` for a record name, to decide conflicts.
    private func localUpdatedAt(_ id: CKRecord.ID) -> Date? {
        guard let (type, key) = Self.split(id) else { return nil }
        switch type {
        case "watch": return (try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first)?.updatedAt
        case "fav": return (try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first)?.updatedAt
        case "override": return (try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first)?.updatedAt
        case "collection": return UUID(uuidString: key).flatMap { u in (try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == u })).first)?.updatedAt }
        case "source": return UUID(uuidString: key).flatMap { u in (try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == u })).first)?.updatedAt }
        case "item": return (try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first)?.updatedAt
        case "groupart": return (try? ctx.fetch(FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.groupID == key })).first)?.updatedAt
        case "file":
            let name = id.recordName
            return (try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.syncKey == name })).first)?.updatedAt
        default: return nil
        }
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let (type, key) = Self.split(id) else { return nil }
        switch type {
        case "summary":
            let r = baseRecord("Summary", id)
            let local = SourceType.local.rawValue
            r["itemCount"] = (try? ctx.fetchCount(FetchDescriptor<MediaItem>())) ?? 0
            r["fileCount"] = (try? ctx.fetchCount(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.source?.typeRaw != local }))) ?? 0
            r["sourceCount"] = (try? ctx.fetchCount(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.typeRaw != local }))) ?? 0
            r["updatedAt"] = Date()
            return r
        case "watch":
            guard let ws = try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first else { return nil }
            let r = baseRecord("WatchState", id)
            r["itemKey"] = ws.itemKey; r["watched"] = ws.watched ? 1 : 0; r["position"] = ws.position; r["duration"] = ws.duration
            r["updatedAt"] = ws.updatedAt; r["deviceID"] = ws.deviceID; r["lastPlayedAt"] = ws.lastPlayedAt
            return r
        case "fav":
            guard let f = try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first else { return nil }
            let r = baseRecord("Favourite", id)
            r["itemKey"] = f.itemKey; r["createdAt"] = f.createdAt; r["deletedAt"] = f.deletedAt; r["updatedAt"] = f.updatedAt
            return r
        case "groupart":
            guard let g = try? ctx.fetch(FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.groupID == key })).first else { return nil }
            let r = baseRecord("GroupArtwork", id)
            r["groupID"] = g.groupID; r["url"] = g.url; r["collageURLs"] = Self.list(g.collageURLs); r["updatedAt"] = g.updatedAt
            return r
        case "override":
            guard let o = try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first else { return nil }
            let r = baseRecord("ItemOverride", id)
            r["fileKey"] = o.fileKey; r["forcedTMDbID"] = o.forcedTMDbID; r["forcedKind"] = o.forcedKindRaw; r["forcedAniDBID"] = o.forcedAniDBID; r["hidden"] = o.hidden ? 1 : 0; r["updatedAt"] = o.updatedAt
            return r
        case "collection":
            guard let uuid = UUID(uuidString: key), let c = try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first else { return nil }
            let r = baseRecord("Collection", id)
            r["name"] = c.name; r["itemKeys"] = Self.list(c.itemKeys); r["updatedAt"] = c.updatedAt; r["artworkURL"] = c.artworkURL; r["collageURLs"] = Self.list(c.collageURLs)
            return r
        case "source":
            guard let uuid = UUID(uuidString: key), let s = try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == uuid })).first, s.type != .local else { return nil }
            let r = baseRecord("Source", id)
            r["name"] = s.name; r["type"] = s.typeRaw; r["host"] = s.host; r["port"] = s.port; r["path"] = s.path
            r["useTLS"] = s.useTLS ? 1 : 0; r["username"] = s.username; r["hidden"] = s.hiddenFromLibrary ? 1 : 0
            r["mac"] = s.macAddress
            r["folderRules"] = Self.list(s.folderRules.map { "\($0.folderPath)|\($0.tagRaw)" })
            r["updatedAt"] = s.updatedAt ?? Date()
            return r
        case "item":
            guard let i = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first else { return nil }
            let r = baseRecord("Item", id)
            r["itemKey"] = i.itemKey; r["kind"] = i.kindRaw; r["tmdbID"] = i.tmdbID; r["title"] = i.title; r["year"] = i.year
            r["overview"] = i.overview; r["posterPath"] = i.posterPath; r["backdropPath"] = i.backdropPath; r["stillPath"] = i.stillPath
            r["rating"] = i.rating; r["runtimeMinutes"] = i.runtimeMinutes; r["genres"] = Self.list(i.genres); r["cast"] = Self.list(i.cast); r["castProfiles"] = Self.list(i.castProfiles); r["castIDs"] = i.castIDs
            r["studios"] = Self.list(i.studios); r["keywords"] = Self.list(i.keywords)
            r["studioLogos"] = Self.list(i.studioLogos); r["collectionPosterPath"] = i.collectionPosterPath
            r["posterOverrideURL"] = i.posterOverrideURL; r["backdropOverrideURL"] = i.backdropOverrideURL; r["logoOverrideURL"] = i.logoOverrideURL
            r["preferredFileID"] = i.preferredFileID?.uuidString
            r["confidence"] = i.confidenceRaw; r["addedAt"] = i.addedAt; r["hidden"] = i.hidden ? 1 : 0
            r["seasonNumber"] = i.seasonNumber; r["episodeNumber"] = i.episodeNumber; r["airDate"] = i.airDate
            r["showKey"] = i.show?.itemKey ?? i.showKeyHint; r["seasonCount"] = i.seasonCount
            r["updatedAt"] = i.updatedAt ?? Date()
            return r
        case "file":
            let name = id.recordName   // syncKey holds the full record name, not just the hash
            guard let f = try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.syncKey == name })).first, let source = f.source, source.type != .local else { return nil }
            let r = baseRecord("File", id)
            r["sourceID"] = source.id.uuidString; r["relativePath"] = f.relativePath; r["size"] = f.size; r["modified"] = f.modified
            r["duration"] = f.duration; r["videoCodec"] = f.videoCodec; r["resolution"] = f.resolution
            r["audioSummary"] = f.audioSummary; r["subtitleSummary"] = f.subtitleSummary
            r["sidecars"] = Self.list(f.sidecars); r["qualityTags"] = Self.list(f.qualityTags); r["classification"] = f.classificationRaw
            r["guessTitle"] = f.guessTitle; r["guessYear"] = f.guessYear; r["guessSeason"] = f.guessSeason; r["guessEpisode"] = f.guessEpisode; r["guessKind"] = f.guessKindRaw
            r["reviewed"] = f.reviewed ? 1 : 0; r["ignored"] = f.ignored ? 1 : 0
            r["itemKey"] = f.item?.itemKey ?? f.itemKeyHint; r["addedAt"] = f.addedAt; r["lastSeenAt"] = f.lastSeenAt
            r["updatedAt"] = f.updatedAt ?? Date()
            return r
        default: return nil
        }
    }

    // MARK: - Applying remote records

    /// Applies one fetched record to `ctx`. Record names of CloudKit records that must be deleted as a
    /// consequence (a re-keyed source's old files) are appended to `deleting` for the caller to send.
    nonisolated static func apply(_ r: CKRecord, in ctx: ModelContext, deleting: inout [String]) {
        let remoteUpdated = (r["updatedAt"] as? Date) ?? .distantPast
        switch r.recordType {
        case "WatchState":
            guard let key = r["itemKey"] as? String else { return }
            let ws = (try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first) ?? { let w = WatchState(itemKey: key, deviceID: "remote"); w.updatedAt = .distantPast; w.pendingSync = false; ctx.insert(w); return w }()
            // A row this device never wrote itself (deviceID "remote", nothing pending) always yields to the record.
            let placeholder = ws.deviceID == "remote" && !ws.pendingSync
            guard placeholder || remoteUpdated > ws.updatedAt else { return }
            ws.watched = ((r["watched"] as? Int) ?? 0) == 1
            ws.position = (r["position"] as? Double) ?? ws.position
            ws.duration = (r["duration"] as? Double) ?? ws.duration
            ws.lastPlayedAt = r["lastPlayedAt"] as? Date
            ws.deviceID = (r["deviceID"] as? String) ?? ws.deviceID
            ws.updatedAt = remoteUpdated; ws.pendingSync = false
        case "Favourite":
            guard let key = r["itemKey"] as? String else { return }
            let f = (try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first) ?? { let x = Favourite(itemKey: key); x.updatedAt = .distantPast; x.pendingSync = false; ctx.insert(x); return x }()
            guard remoteUpdated > f.updatedAt || (!f.pendingSync && f.createdAt == f.updatedAt && f.deletedAt == nil && remoteUpdated >= f.updatedAt) else { return }
            f.createdAt = (r["createdAt"] as? Date) ?? f.createdAt
            f.deletedAt = r["deletedAt"] as? Date
            f.updatedAt = remoteUpdated; f.pendingSync = false
        case "GroupArtwork":
            guard let key = r["groupID"] as? String else { return }
            let g = (try? ctx.fetch(FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.groupID == key })).first) ?? { let x = GroupArtwork(groupID: key); x.updatedAt = .distantPast; x.pendingSync = false; ctx.insert(x); return x }()
            guard remoteUpdated > g.updatedAt else { return }
            g.url = r["url"] as? String
            g.collageURLs = (r["collageURLs"] as? [String]) ?? []
            g.updatedAt = remoteUpdated; g.pendingSync = false
        case "ItemOverride":
            guard let key = r["fileKey"] as? String else { return }
            let o = (try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first) ?? { let x = ItemOverride(fileKey: key); x.updatedAt = .distantPast; x.pendingSync = false; ctx.insert(x); return x }()
            guard remoteUpdated > o.updatedAt else { return }
            o.forcedTMDbID = r["forcedTMDbID"] as? Int
            o.forcedKindRaw = r["forcedKind"] as? String
            o.forcedAniDBID = r["forcedAniDBID"] as? Int
            o.hidden = ((r["hidden"] as? Int) ?? 0) == 1
            o.updatedAt = remoteUpdated; o.pendingSync = false
        case "Collection":
            guard let (_, key) = Self.split(r.recordID), let uuid = UUID(uuidString: key) else { return }
            let c = (try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first) ?? { let x = MediaCollection(name: ""); x.id = uuid; x.updatedAt = .distantPast; x.pendingSync = false; ctx.insert(x); return x }()
            guard remoteUpdated > c.updatedAt else { return }
            c.name = (r["name"] as? String) ?? c.name
            c.itemKeys = (r["itemKeys"] as? [String]) ?? c.itemKeys
            c.artworkURL = r["artworkURL"] as? String
            c.collageURLs = (r["collageURLs"] as? [String]) ?? []
            c.updatedAt = remoteUpdated; c.pendingSync = false
        case "Source":
            guard let (_, key) = Self.split(r.recordID), let uuid = UUID(uuidString: key),
                  let typeRaw = r["type"] as? String, let type = SourceType(rawValue: typeRaw), type != .local else { return }
            let existing = try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == uuid })).first
            if let existing, let local = existing.updatedAt, local >= remoteUpdated { return }
            // Same share already present under another id (each device added it before sync existed). Both
            // devices must end up on ONE id or their file records (and so Needs Review, reviewed, ignored)
            // never meet. Rule: the smaller UUID wins. If the remote id is smaller we re-key our source to it
            // and re-upload our files under the new names; otherwise we ignore the remote copy and the other
            // device re-keys when it receives ours.
            let identity = Self.identity(type: type, host: (r["host"] as? String) ?? "", path: (r["path"] as? String) ?? "")
            var adopted: SourceRecord? = existing
            if existing == nil, let twin = ((try? ctx.fetch(FetchDescriptor<SourceRecord>())) ?? []).first(where: { $0.id != uuid && Self.identity(type: $0.type, host: $0.host, path: $0.path) == identity }) {
                guard uuid.uuidString < twin.id.uuidString else { return }
                adopted = Self.rekey(twin, to: uuid, in: ctx, deleting: &deleting)
            }
            let config = SourceConfig(id: uuid, name: (r["name"] as? String) ?? "Source", type: type, host: (r["host"] as? String) ?? "",
                                      port: r["port"] as? Int, path: (r["path"] as? String) ?? "", useTLS: ((r["useTLS"] as? Int) ?? 1) == 1, username: r["username"] as? String)
            let s = adopted ?? { let x = SourceRecord(config: config); ctx.insert(x); return x }()
            s.name = config.name; s.typeRaw = config.type.rawValue; s.host = config.host; s.port = config.port; s.path = config.path
            s.useTLS = config.useTLS; s.username = config.username
            if let mac = r["mac"] as? String, !mac.isEmpty { s.macAddress = mac }
            s.hiddenFromLibrary = ((r["hidden"] as? Int) ?? 0) == 1
            // Folder rules merge by path: remote entries win, local-only entries survive. A remote record with
            // no rules (the other device scans the root) must not wipe this device's folder choices, and in
            // that case ours are pushed so both devices end up with the same rules.
            let remoteRules: [(String, FolderTag)] = ((r["folderRules"] as? [String]) ?? []).compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let tag = FolderTag(rawValue: parts[1]) else { return nil }
                return (parts[0], tag)
            }
            var merged: [String: FolderTag] = [:]
            for rule in s.folderRules { merged[rule.folderPath] = rule.tag }
            for (path, tag) in remoteRules { merged[path] = tag }
            let changedLocally = merged.count != remoteRules.count
            var seenPaths = Set<String>()
            for rule in s.folderRules {
                if let tag = merged[rule.folderPath], !seenPaths.contains(rule.folderPath) {
                    rule.tagRaw = tag.rawValue; rule.includeInScan = tag != .excluded; seenPaths.insert(rule.folderPath)
                } else {
                    ctx.delete(rule)   // gone remotely, or a duplicate row
                }
            }
            for (path, tag) in merged where !seenPaths.contains(path) {
                let fr = FolderRule(folderPath: path, tag: tag, includeInScan: tag != .excluded); fr.source = s; s.folderRules.append(fr)
            }
            s.updatedAt = changedLocally ? Date() : remoteUpdated
            s.pendingSync = changedLocally
        case "Item":
            guard let key = r["itemKey"] as? String, let kindRaw = r["kind"] as? String, let kind = MediaKind(rawValue: kindRaw) else { return }
            let existing = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first
            if let existing, let local = existing.updatedAt, local >= remoteUpdated { return }
            let i = existing ?? {
                let x = MediaItem(itemKey: key, kind: kind, title: (r["title"] as? String) ?? "", confidence: .autoHigh); ctx.insert(x); return x
            }()
            i.kindRaw = kindRaw; i.tmdbID = r["tmdbID"] as? Int; i.title = (r["title"] as? String) ?? i.title
            i.sortTitle = MediaItem.makeSortTitle(i.title)
            i.year = r["year"] as? Int; i.overview = r["overview"] as? String
            i.posterPath = r["posterPath"] as? String; i.backdropPath = r["backdropPath"] as? String; i.stillPath = r["stillPath"] as? String
            i.rating = r["rating"] as? Double; i.runtimeMinutes = r["runtimeMinutes"] as? Int
            i.genres = (r["genres"] as? [String]) ?? []; i.cast = (r["cast"] as? [String]) ?? []
            if let profiles = r["castProfiles"] as? [String], profiles.count == i.cast.count { i.castProfiles = profiles }
            if let ids = r["castIDs"] as? [Int], ids.count == i.cast.count { i.castIDs = ids }
            if let s = r["studios"] as? [String] { i.studios = s }
            if let k = r["keywords"] as? [String] { i.keywords = k }
            if let l = r["studioLogos"] as? [String], l.count == i.studios.count { i.studioLogos = l }
            if let cp = r["collectionPosterPath"] as? String { i.collectionPosterPath = cp }
            i.posterOverrideURL = r["posterOverrideURL"] as? String; i.backdropOverrideURL = r["backdropOverrideURL"] as? String; i.logoOverrideURL = r["logoOverrideURL"] as? String
            i.preferredFileID = (r["preferredFileID"] as? String).flatMap(UUID.init)
            i.confidenceRaw = (r["confidence"] as? String) ?? i.confidenceRaw
            i.addedAt = (r["addedAt"] as? Date) ?? i.addedAt; i.hidden = ((r["hidden"] as? Int) ?? 0) == 1
            i.seasonNumber = r["seasonNumber"] as? Int; i.episodeNumber = r["episodeNumber"] as? Int; i.airDate = r["airDate"] as? Date
            i.seasonCount = r["seasonCount"] as? Int
            i.showKeyHint = r["showKey"] as? String
            i.updatedAt = remoteUpdated; i.pendingSync = false
        case "File":
            guard let sid = (r["sourceID"] as? String).flatMap(UUID.init(uuidString:)), let path = r["relativePath"] as? String else { return }
            guard let source = try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == sid })).first else { return } // source arrives first or never
            let existing = try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.relativePath == path && $0.source?.id == sid })).first
            // Decisions are sticky whichever side is newer: reviewed/ignored merge with OR, and a match
            // (itemKey set) beats an unmatched copy. Only then does latest-wins apply to the rest.
            if let existing {
                if ((r["reviewed"] as? Int) ?? 0) == 1, !existing.reviewed { existing.reviewed = true }
                if ((r["ignored"] as? Int) ?? 0) == 1, !existing.ignored { existing.ignored = true; existing.classificationRaw = "ignored" }
                let remoteMatched = (r["itemKey"] as? String) != nil
                if let local = existing.updatedAt, local >= remoteUpdated, !(remoteMatched && existing.item == nil && existing.itemKeyHint == nil) { return }
            }
            let f = existing ?? {
                let x = MediaFile(relativePath: path, size: (r["size"] as? Int64) ?? 0, modified: r["modified"] as? Date, source: source); ctx.insert(x); return x
            }()
            f.size = (r["size"] as? Int64) ?? f.size; f.modified = r["modified"] as? Date
            f.duration = r["duration"] as? Double; f.videoCodec = r["videoCodec"] as? String; f.resolution = r["resolution"] as? String
            f.audioSummary = r["audioSummary"] as? String; f.subtitleSummary = r["subtitleSummary"] as? String
            f.sidecars = (r["sidecars"] as? [String]) ?? []; f.qualityTags = (r["qualityTags"] as? [String]) ?? []
            f.classificationRaw = (r["classification"] as? String) ?? f.classificationRaw
            f.guessTitle = r["guessTitle"] as? String; f.guessYear = r["guessYear"] as? Int; f.guessSeason = r["guessSeason"] as? Int
            f.guessEpisode = r["guessEpisode"] as? Int; f.guessKindRaw = r["guessKind"] as? String
            f.reviewed = f.reviewed || ((r["reviewed"] as? Int) ?? 0) == 1; f.ignored = f.ignored || ((r["ignored"] as? Int) ?? 0) == 1
            f.addedAt = (r["addedAt"] as? Date) ?? f.addedAt; f.lastSeenAt = (r["lastSeenAt"] as? Date) ?? f.lastSeenAt
            f.itemKeyHint = r["itemKey"] as? String
            // Link now when the item is already here, so a tap during a restore finds the file.
            if f.item == nil, let key = f.itemKeyHint, let item = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first { f.item = item }
            f.syncKey = r.recordID.recordName
            f.updatedAt = remoteUpdated; f.pendingSync = false
        default: break
        }
    }

    /// Records arrive in no particular order, so relationships are resolved from the key hints once
    /// both sides exist. Cheap: only rows whose link is still missing are fetched.
    nonisolated static func reconcileLinks(in ctx: ModelContext) {
        let orphanFiles = (try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.itemKeyHint != nil && $0.item == nil }))) ?? []
        for f in orphanFiles {
            guard let key = f.itemKeyHint, let item = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first else { continue }
            f.item = item
        }
        let orphanEpisodes = (try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.showKeyHint != nil && $0.show == nil }))) ?? []
        for e in orphanEpisodes {
            guard let key = e.showKeyHint, let show = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first else { continue }
            e.show = show
        }
    }

    nonisolated static func applyDeletion(_ id: CKRecord.ID, in ctx: ModelContext) {
        guard let (type, key) = Self.split(id) else { return }
        switch type {
        case "collection":
            if let uuid = UUID(uuidString: key), let c = try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first { ctx.delete(c) }
        case "source":
            if let uuid = UUID(uuidString: key), let s = try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == uuid })).first {
                CredentialStore.shared.remove(for: uuid)
                ctx.delete(s)
            }
        case "item":
            if let i = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first { ctx.delete(i) }
        case "file":
            let name = id.recordName
            if let f = try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.syncKey == name })).first { ctx.delete(f) }
        default: break
        }
    }

    private func clearPending(_ id: CKRecord.ID) {
        guard let (type, key) = Self.split(id) else { return }
        switch type {
        case "watch": if let x = try? ctx.fetch(FetchDescriptor<WatchState>(predicate: #Predicate { $0.itemKey == key })).first { x.pendingSync = false }
        case "fav": if let x = try? ctx.fetch(FetchDescriptor<Favourite>(predicate: #Predicate { $0.itemKey == key })).first { x.pendingSync = false }
        case "override": if let x = try? ctx.fetch(FetchDescriptor<ItemOverride>(predicate: #Predicate { $0.fileKey == key })).first { x.pendingSync = false }
        case "groupart": if let x = try? ctx.fetch(FetchDescriptor<GroupArtwork>(predicate: #Predicate { $0.groupID == key })).first { x.pendingSync = false }
        case "collection": if let uuid = UUID(uuidString: key), let x = try? ctx.fetch(FetchDescriptor<MediaCollection>(predicate: #Predicate { $0.id == uuid })).first { x.pendingSync = false }
        case "source": if let uuid = UUID(uuidString: key), let x = try? ctx.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == uuid })).first { x.pendingSync = false }
        case "item": if let x = try? ctx.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.itemKey == key })).first { x.pendingSync = false }
        case "file":
            let name = id.recordName
            if let x = try? ctx.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate { $0.syncKey == name })).first { x.pendingSync = false }
        default: break
        }
    }
}

/// Applies fetched CloudKit changes on its own context, off the main thread. The main context picks
/// the rows up through the container, and `SyncEngine.onChangesApplied` tells the screens to refresh.
@ModelActor
actor SyncApplier {
    /// Returns the CloudKit record names that must now be deleted (a re-keyed source's old files).
    func apply(modifications: [CKRecord], deletions: [CKRecord.ID]) -> AppliedBatch {
        var out = AppliedBatch()
        for r in modifications {
            switch r.recordType {
            case "Source": out.sources += 1
            case "Item": out.items += 1
            case "File": out.files += 1
            case "Summary":
                out.expectedItems = r["itemCount"] as? Int
                out.expectedFiles = r["fileCount"] as? Int
                SyncEngine.rememberSystemFields(r, in: modelContext)   // marks it as seen; nothing else is stored
                continue
            default: break
            }
            SyncEngine.rememberSystemFields(r, in: modelContext)
            SyncEngine.apply(r, in: modelContext, deleting: &out.toDelete)
        }
        for id in deletions { SyncEngine.forgetSystemFields(id, in: modelContext); SyncEngine.applyDeletion(id, in: modelContext) }
        SyncEngine.reconcileLinks(in: modelContext)
        SyncEngine.dedupeSources(in: modelContext)
        try? modelContext.save()
        return out
    }
}
#endif
