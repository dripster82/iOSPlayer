import Foundation
import Combine
import SwiftUI
import MediaCore
import Library

/// A saved filter that reads like a collection: "Unwatched Marvel", "Films under 100 minutes",
/// "Added this month". Rules live on the device; the matching titles are computed when shown.
struct SmartCollection: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case any = "Films and shows", films = "Films", shows = "Shows" }
    var id = UUID()
    var name: String
    var kind: Kind = .any
    var unwatchedOnly = false
    var favouritesOnly = false
    var genre: String? = nil
    var universe: String? = nil
    var maxRuntimeMinutes: Int? = nil
    var minRating: Double? = nil
    var addedWithinDays: Int? = nil
    var decade: String? = nil

    var summary: String {
        var parts: [String] = [kind.rawValue]
        if unwatchedOnly { parts.append("unwatched") }
        if favouritesOnly { parts.append("favourites") }
        if let genre { parts.append(genre) }
        if let universe { parts.append(universe) }
        if let m = maxRuntimeMinutes { parts.append("under \(m) min") }
        if let r = minRating { parts.append("★ \(String(format: "%.1f", r))+") }
        if let d = addedWithinDays { parts.append("added in the last \(d) days") }
        if let decade { parts.append(decade) }
        return parts.joined(separator: " · ")
    }

    @MainActor func matches(in library: LibraryStore) -> [MediaItem] {
        var items: [MediaItem] = []
        if kind != .shows { items += library.items(kind: .film) }
        if kind != .films { items += library.items(kind: .show) }
        let since = addedWithinDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        return items.filter { i in
            if unwatchedOnly {
                if i.kind == .show { if library.unwatchedCount(i) == 0 { return false } }
                else if library.watchState(i.itemKey)?.watched == true { return false }
            }
            if favouritesOnly, !library.isFavourite(i.itemKey) { return false }
            if let genre, !i.genres.contains(genre) { return false }
            if let universe, !Universes.universes(studios: i.studios, keywords: i.keywords).contains(universe) { return false }
            if let m = maxRuntimeMinutes, let r = i.runtimeMinutes, r > m { return false }
            if let minRating, (i.rating ?? 0) < minRating { return false }
            if let since, i.addedAt < since { return false }
            if let decade, let y = i.year, "\(y / 10 * 10)s" != decade { return false }
            return true
        }.sorted { $0.sortTitle < $1.sortTitle }
    }
}

@MainActor
final class SmartCollectionStore: ObservableObject {
    @Published private(set) var all: [SmartCollection] = []
    private let library: LibraryStore
    private var watcher: AnyCancellable?

    /// Rules are kept as `MediaCollection` rows with `smartRules` set, so they sync like the hand-made
    /// collections. Rules an earlier build kept in UserDefaults move over once.
    init(library: LibraryStore) {
        self.library = library
        if let data = UserDefaults.standard.data(forKey: "reel.smartCollections"), let old = try? JSONDecoder().decode([SmartCollection].self, from: data) {
            for c in old { save(c) }
            UserDefaults.standard.removeObject(forKey: "reel.smartCollections")
        }
        reload()
        watcher = library.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
    }
    private func reload() {
        let rules = library.smartCollections().compactMap { c -> SmartCollection? in
            guard let json = c.smartRules, var r = try? JSONDecoder().decode(SmartCollection.self, from: Data(json.utf8)) else { return nil }
            r.id = c.id; r.name = c.name; return r
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if rules != all { all = rules }
    }
    func save(_ c: SmartCollection) {
        guard let data = try? JSONEncoder().encode(c), let json = String(data: data, encoding: .utf8) else { return }
        library.saveSmartCollection(id: c.id, name: c.name, rules: json)
        reload()
    }
    func remove(_ id: UUID) { library.removeCollection(id: id); reload() }
}
