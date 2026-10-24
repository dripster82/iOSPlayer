import Foundation
import Library
import Metadata

/// Where each piece of an item's artwork comes from: the user's pick in Edit artwork first, else the
/// automatic choice (TMDb, or fanart.tv for logos and backdrops when TMDb has none).
extension MediaItem {
    var posterURL: URL? { posterOverrideURL.flatMap(URL.init) ?? ArtworkURL.poster(posterPath) }
    func posterURL(size: ArtworkURL.PosterSize) -> URL? { posterOverrideURL.flatMap(URL.init) ?? ArtworkURL.poster(posterPath, size: size) }
    var backdropURL: URL? { backdropOverrideURL.flatMap(URL.init) ?? ArtworkURL.backdrop(backdropPath) ?? extraBackdropURL.flatMap(URL.init) }
    func backdropURL(size: ArtworkURL.BackdropSize) -> URL? { backdropOverrideURL.flatMap(URL.init) ?? ArtworkURL.backdrop(backdropPath, size: size) ?? extraBackdropURL.flatMap(URL.init) }
    var titleLogoURL: URL? { logoOverrideURL.flatMap(URL.init) ?? logoURL.flatMap(URL.init) }
}
