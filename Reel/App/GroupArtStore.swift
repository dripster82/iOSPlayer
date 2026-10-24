import Foundation
import SwiftUI
import Library

/// Artwork picks for universes and film series. Backed by `GroupArtwork` rows in the library (so
/// they sync); this object exists so views get a change signal and a simple API. The first launch
/// after the move imports the picks the previous build kept in UserDefaults.
@MainActor
final class GroupArtStore: ObservableObject {
    struct Art: Codable, Equatable {
        var url: String?
        var collage: [String] = []
        var isEmpty: Bool { url == nil && collage.isEmpty }
    }
    private let library: LibraryStore
    @Published private(set) var version = 0

    init(library: LibraryStore) {
        self.library = library
        importLegacy()
    }

    func art(for id: String) -> Art? {
        library.groupArtwork(for: id).map { Art(url: $0.url, collage: $0.collageURLs) }
    }
    func set(_ art: Art?, for id: String) {
        library.setGroupArtwork(url: art?.url, collage: art?.collage ?? [], for: id)
        version += 1
    }

    private func importLegacy() {
        let key = "reel.groupArt"
        guard let data = UserDefaults.standard.data(forKey: key), let old = try? JSONDecoder().decode([String: Art].self, from: data) else { return }
        for (id, art) in old where !art.isEmpty && library.groupArtwork(for: id) == nil {
            library.setGroupArtwork(url: art.url, collage: art.collage, for: id)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
