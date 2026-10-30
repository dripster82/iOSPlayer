import Foundation
import UIKit
import MediaCore
import Library
import MediaSources
#if canImport(VLCKit)
import VLCKit
#endif

/// Reads a book's embedded tags with VLC (title, author, narrator, year, cover) from its first part
/// and writes them onto the book. m4b files from the usual tools carry all of it; mp3 parts carry
/// ID3 tags with the album as the book and the artist as the author. One book at a time, after a
/// scan and at launch, for books not read yet; a part that will not open is left to the names.
@MainActor
enum AudiobookTags {
    private static var running = false

    static func readPending(library: LibraryStore) {
        guard !running else { return }
        let pending = library.booksNeedingTags()
        guard !pending.isEmpty else { AudiobookMetadata.lookupPending(library: library); return }
        running = true
        Diagnostics.log("library", "reading tags for \(pending.count) audiobooks")
        Task {
            defer { running = false }
            for (book, file) in pending {
                guard DeviceConditions.allowsBackgroundWork else { break }
                guard let (url, _) = try? await library.playbackURL(for: file) else { continue }
                let tags = await read(url)
                let folderCover = await coverBeside(file, library: library)
                library.applyBookTags(book, title: tags?.title, author: tags?.author, narrator: tags?.narrator, year: tags?.year, cover: tags?.cover ?? folderCover)
                if book === pending.last?.0 { AudiobookMetadata.lookupPending(library: library) }
                Diagnostics.log("library", "tags for \(book.title.prefix(40)): \(tags.map { "title \"\($0.title ?? "")\", author \"\($0.author ?? "")\", cover \($0.cover != nil)" } ?? "none read")\(folderCover != nil ? ", cover beside the parts" : "")")
            }
        }
    }

    struct Tags { var title: String?; var author: String?; var narrator: String?; var year: Int?; var cover: Data? }

    /// Parses the file's header through VLC; a few seconds at most, nothing decoded.
    static func read(_ url: URL) async -> Tags? {
        #if canImport(VLCKit)
        guard let media = VLCMedia(url: url) else { return nil }
        _ = media.parse(options: [.parseNetwork, .fetchLocal], timeout: 15000)
        var waited = 0
        while media.parsedStatus != .done, media.parsedStatus != .failed, media.parsedStatus != .timeout, waited < 160 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
        guard media.parsedStatus == .done else { return nil }
        let m = media.metaData
        func clean(_ s: String?) -> String? { let t = s?.trimmingCharacters(in: CharacterSet.whitespaces) ?? ""; return t.isEmpty ? nil : t }
        // The album is the book for a part; the title is the book for a single file (or the part's own name).
        let album = clean(m.album), title = clean(m.title)
        let titleIsPart = (title ?? "").lowercased().hasPrefix("part") || (title ?? "").lowercased().hasPrefix("track") || (title ?? "").lowercased().hasPrefix("chapter")
        let book = album ?? (titleIsPart ? nil : title)
        let author = clean(m.albumArtist) ?? clean(m.artist)
        // Narrators land in various fields: the composer slot is not exposed, so look at the extras.
        let narrator = m.extra?.first { k, _ in ["composer", "narrator", "performer", "©nrt", "nrt"].contains(k.lowercased()) }?.value
        let year = m.date.flatMap { Int($0.prefix(4)) }
        var cover: Data?
        if let image = m.artwork { cover = image.jpegData(compressionQuality: 0.85) }
        else if let art = m.artworkURL, art.isFileURL { cover = try? Data(contentsOf: art) }
        return Tags(title: book, author: author, narrator: narrator, year: year, cover: cover)
        #else
        return nil
        #endif
    }

    /// cover.jpg, folder.jpg or any picture in the part's folder, read over the share.
    static func coverBeside(_ file: MediaFile, library: LibraryStore) async -> Data? {
        guard let record = file.source else { return nil }
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        let src = SourceFactory.make(record.config)
        do {
            try await src.connect(credentials: CredentialStore.shared.load(for: record.id))
            defer { Task { await src.disconnect() } }
            let pictures = try await src.list(folder).filter { !$0.isDirectory && ["jpg", "jpeg", "png"].contains($0.fileExtension) && ($0.size ?? 0) < 5_000_000 }
            let preferred = pictures.first { p in ["cover", "folder", "front", "album"].contains { w in p.name.lowercased().contains(w) } } ?? pictures.first
            guard let pick = preferred, let size = pick.size, size > 0 else { return nil }
            return try await src.read(pick.relativePath, offset: 0, length: Int(size))
        } catch { return nil }
    }
}
