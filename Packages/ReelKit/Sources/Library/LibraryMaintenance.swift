#if canImport(SwiftData)
import Foundation
import SwiftData

/// Bulk library edits that must not run on the main thread. Same pattern as `LibraryScanner`.
@ModelActor
public actor LibraryMaintenance {

    /// Deletes every file under `folder` for one source, then any item (and show) left with no files.
    /// An empty folder means the whole source.
    /// Returns the CloudKit record names of everything removed, for the sync engine.
    @discardableResult
    public func purgeFiles(under folder: String, sourceID: UUID) throws -> [String] {
        var deleted: [String] = []
        let prefix = folder.isEmpty ? "" : folder.hasSuffix("/") ? folder : folder + "/"
        let files = try modelContext.fetch(FetchDescriptor<MediaFile>(predicate: #Predicate {
            $0.source?.id == sourceID && ($0.relativePath.starts(with: prefix) || $0.relativePath == folder)
        }))
        var itemIDs = Set<PersistentIdentifier>()
        for file in files {
            if let item = file.item { itemIDs.insert(item.persistentModelID) }
            deleted.append(SyncKeys.file(sourceID: sourceID, relativePath: file.relativePath))
            modelContext.delete(file)
        }
        try modelContext.save()

        var showIDs = Set<PersistentIdentifier>()
        for id in itemIDs {
            guard let item = modelContext.model(for: id) as? MediaItem, !item.isDeleted, item.files.isEmpty else { continue }
            if let show = item.show { showIDs.insert(show.persistentModelID) }
            deleted.append(SyncKeys.item(item.itemKey))
            modelContext.delete(item)
        }
        try modelContext.save()
        for id in showIDs {
            guard let show = modelContext.model(for: id) as? MediaItem, !show.isDeleted, show.episodes.isEmpty else { continue }
            deleted.append(SyncKeys.item(show.itemKey))
            modelContext.delete(show)
        }
        try modelContext.save()
        return deleted
    }
}
#endif
