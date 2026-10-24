import Foundation
import SwiftUI

/// Artwork the user picked for a universe or film series. Those groups are computed, not stored,
/// so their choices live here, keyed by the group's id. Per device; nothing to sync them through yet.
final class GroupArtStore: ObservableObject {
    struct Art: Codable, Equatable {
        /// A single picture (logo, poster or backdrop URL) to use as the card, or nil for a collage.
        var url: String?
        /// Up to four poster URLs for the collage; empty means the group's first four films.
        var collage: [String] = []
        var isEmpty: Bool { url == nil && collage.isEmpty }
    }
    private let key = "reel.groupArt"
    @Published private(set) var all: [String: Art]

    init() { all = (UserDefaults.standard.data(forKey: "reel.groupArt")).flatMap { try? JSONDecoder().decode([String: Art].self, from: $0) } ?? [:] }

    func art(for id: String) -> Art? { all[id] }
    func set(_ art: Art?, for id: String) {
        if let art, !art.isEmpty { all[id] = art } else { all.removeValue(forKey: id) }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}
