import Foundation
import Library

extension MediaItem {
    /// Seasons that actually have files in the library (distinct season numbers across the show's episodes).
    var localSeasonCount: Int { Set(episodes.compactMap(\.seasonNumber)).count }

    /// "3 of 7 seasons" when the library holds fewer than TMDb lists, otherwise just "7 seasons".
    var seasonsLabel: String {
        let have = localSeasonCount
        let total = seasonCount ?? have
        let n = max(have, total)
        let noun = "season" + (n == 1 ? "" : "s")
        return have < total ? "\(have) of \(total) \(noun)" : "\(n) \(noun)"
    }
}
