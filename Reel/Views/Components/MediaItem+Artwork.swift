import Foundation
import Library
import Metadata

/// Where each piece of an item's artwork comes from: the user's pick in Edit artwork first, else the
/// automatic choice (TMDb, or fanart.tv for logos and backdrops when TMDb has none).
extension MediaItem {
    var posterURL: URL? { posterOverride.flatMap(Self.artworkURL) ?? LibraryStore.coverURL(self) ?? ArtworkURL.poster(posterPath) }
    func posterURL(size: ArtworkURL.PosterSize) -> URL? { posterOverride.flatMap(Self.artworkURL) ?? LibraryStore.coverURL(self) ?? ArtworkURL.poster(posterPath, size: size) }
    /// A part of a book has no artwork of its own: the book's chosen cover (Audible's, or the
    /// listener's pick) stands for it, as the embedded cover already does.
    private var posterOverride: String? { posterOverrideURL ?? (isAudiobookPart ? show?.posterOverrideURL : nil) }
    var backdropURL: URL? { backdropOverrideURL.flatMap(Self.artworkURL) ?? ArtworkURL.backdrop(backdropPath) ?? extraBackdropURL.flatMap(URL.init) }
    func backdropURL(size: ArtworkURL.BackdropSize) -> URL? { backdropOverrideURL.flatMap(Self.artworkURL) ?? ArtworkURL.backdrop(backdropPath, size: size) ?? extraBackdropURL.flatMap(URL.init) }
    var stillURL: URL? { stillPath.flatMap { $0.hasPrefix("demo://") ? Self.artworkURL($0) : nil } ?? ArtworkURL.still(stillPath) }
    var titleLogoURL: URL? { logoOverrideURL.flatMap(URL.init) ?? logoURL.flatMap(URL.init) }

    /// An override is an absolute URL, except the sample library's "demo://<file>", which is a
    /// picture in the bundle (the bundle's path is not stable across installs, so it is not stored).
    static func artworkURL(_ string: String) -> URL? {
        if string.hasPrefix("demo://") { return DemoLibrary.artURL(String(string.dropFirst(7))) }
        return URL(string: string)
    }
}
