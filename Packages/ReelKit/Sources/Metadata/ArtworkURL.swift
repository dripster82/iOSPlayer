import Foundation

/// Builds TMDb image URLs at the sizes PLAN.md §11.5 chose.
public enum ArtworkURL {
    public static let base = URL(string: "https://image.tmdb.org/t/p/")!

    public enum PosterSize: String { case grid = "w342", detail = "w780" }
    public enum BackdropSize: String { case detail = "w1280", small = "w780" }
    public enum StillSize: String { case list = "w300", detail = "original" }
    public enum ProfileSize: String { case avatar = "w185" }

    public static func poster(_ path: String?, size: PosterSize = .grid) -> URL? { url(path, size.rawValue) }
    public static func backdrop(_ path: String?, size: BackdropSize = .detail) -> URL? { url(path, size.rawValue) }
    public static func still(_ path: String?, size: StillSize = .list) -> URL? { url(path, size.rawValue) }
    public static func profile(_ path: String?, size: ProfileSize = .avatar) -> URL? { url(path, size.rawValue) }

    private static func url(_ path: String?, _ size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(size).appendingPathComponent(trimmed)
    }
}
