import Foundation
import SwiftData
import MediaCore
import MediaSources
import Library

/// The sample library: three short films and a three-episode show shipped inside the app, with their
/// own artwork, so Reel can be tried (and reviewed) with no NAS, no account and no API key. The
/// titles are made up and the clips are generated test patterns; nothing is passed off as real media.
/// Installing adds a local source that points into the bundle and inserts the titles directly, so no
/// metadata lookup runs. Removing it takes the source and every title it owned away again.
@MainActor
enum DemoLibrary {
    static let sourceName = "Sample library"
    static let folder = "Demo"
    private static let sourceID = UUID(uuidString: "7D3B2A10-5E1F-4C8A-9B2D-0A6F5E4C3D21")!

    nonisolated static func artURL(_ file: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("Art", isDirectory: true).appendingPathComponent(file)
    }

    static var isInstalled: Bool { get { false } }

    static func installed(in library: LibraryStore) -> SourceRecord? {
        library.sources().first { $0.id == sourceID }
    }

    struct Film { var file: String; var title: String; var year: Int; var runtime: Int; var genres: [String]; var rating: Double; var overview: String; var art: String }
    static let films: [Film] = [
        Film(file: "Films/Aurora Over the Fjord (2021).mp4", title: "Aurora Over the Fjord", year: 2021, runtime: 96, genres: ["Drama", "Adventure"], rating: 7.4,
             overview: "A marine biologist returns to the village she left at eighteen to close her late father's research station, and finds the fjord has not finished with her.", art: "aurora"),
        Film(file: "Films/Clockwork Harbour (2019).mp4", title: "Clockwork Harbour", year: 2019, runtime: 104, genres: ["Mystery", "Comedy"], rating: 6.9,
             overview: "When the town's tide clock stops for the first time in two hundred years, a retired watchmaker and a bored customs officer are the only ones who notice.", art: "clockwork"),
        Film(file: "Films/The Last Lighthouse (2023).mp4", title: "The Last Lighthouse", year: 2023, runtime: 88, genres: ["Thriller"], rating: 7.8,
             overview: "The final keeper of an automated light has one night left before the station is decommissioned. Then the radio starts answering.", art: "lighthouse"),
    ]
    struct Episode { var file: String; var number: Int; var title: String; var overview: String; var still: String }
    static let show = (title: "Starfall Station", year: 2022, genres: ["Science Fiction", "Drama"], rating: 8.1,
                       overview: "Life aboard a refuelling station at the edge of the shipping lanes, where every arrival brings news from a war nobody on board has seen.")
    static let episodes: [Episode] = [
        Episode(file: "TV/Starfall Station/Season 1/Starfall Station - S01E01 - Arrival.mp4", number: 1, title: "Arrival", overview: "A new engineer docks with orders nobody expected.", still: "e1.jpg"),
        Episode(file: "TV/Starfall Station/Season 1/Starfall Station - S01E02 - Low Orbit.mp4", number: 2, title: "Low Orbit", overview: "A fuel tender drifts off course and the station must decide whether to catch it.", still: "e2.jpg"),
        Episode(file: "TV/Starfall Station/Season 1/Starfall Station - S01E03 - Night Shift.mp4", number: 3, title: "Night Shift", overview: "The night crew hears a transmission that was meant for someone else.", still: "e3.jpg"),
    ]

    /// Adds the source and its titles. Safe to call when already installed.
    static func install(in library: LibraryStore) {
        guard installed(in: library) == nil else { return }
        let config = SourceConfig(id: sourceID, name: sourceName, type: .local, path: LocalSource.bundlePrefix + folder)
        guard let record = try? library.addSource(config, credentials: nil, folderRules: []) else { return }
        let ctx = library.context
        func attributes(_ rel: String) -> (Int64, Date?) {
            let url = Bundle.main.resourceURL?.appendingPathComponent(folder).appendingPathComponent(rel)
            let v = try? url?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (Int64(v?.fileSize ?? 0), v?.contentModificationDate)
        }
        func file(_ rel: String, kind: String) -> MediaFile {
            let (bytes, modified) = attributes(rel)
            let f = MediaFile(relativePath: rel, size: bytes, modified: modified, source: record)
            f.classificationRaw = kind
            f.reviewed = true
            f.resolution = "360p"
            f.videoCodec = "H.264"
            f.audioSummary = "AAC stereo"
            ctx.insert(f)
            return f
        }
        for film in films {
            let item = MediaItem(itemKey: "demo:film:\(film.art)", kind: .film, title: film.title, year: film.year, confidence: .manual)
            item.overview = film.overview; item.genres = film.genres; item.rating = film.rating; item.runtimeMinutes = film.runtime
            item.posterOverrideURL = "demo://\(film.art).jpg"
            item.backdropOverrideURL = "demo://\(film.art)-backdrop.jpg"
            item.cast = []
            ctx.insert(item)
            file(film.file, kind: "film").item = item
        }
        let showItem = MediaItem(itemKey: "demo:show:starfall", kind: .show, title: show.title, year: show.year, confidence: .manual)
        showItem.overview = show.overview; showItem.genres = show.genres; showItem.rating = show.rating; showItem.seasonCount = 1
        showItem.posterOverrideURL = "demo://starfall.jpg"
        showItem.backdropOverrideURL = "demo://starfall-backdrop.jpg"
        ctx.insert(showItem)
        for ep in episodes {
            let item = MediaItem(itemKey: "demo:show:starfall:S01E\(String(format: "%02d", ep.number))", kind: .episode, title: ep.title, year: show.year, confidence: .manual)
            item.seasonNumber = 1; item.episodeNumber = ep.number; item.overview = ep.overview; item.runtimeMinutes = 22
            item.stillPath = "demo://\(ep.still)"
            item.show = showItem
            ctx.insert(item)
            file(ep.file, kind: "episode").item = item
        }
        record.status = .online
        record.lastScan = Date()
        try? ctx.save()
        library.invalidateCaches()
        library.objectWillChange.send()
        Diagnostics.log("library", "sample library installed")
    }

    static func remove(from library: LibraryStore) {
        guard let record = installed(in: library) else { return }
        try? library.removeSource(record)
        library.invalidateCaches()
        library.objectWillChange.send()
        Diagnostics.log("library", "sample library removed")
    }
}
