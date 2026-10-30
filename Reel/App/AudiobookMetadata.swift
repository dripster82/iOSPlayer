import Foundation
import MediaCore
import Library
import Metadata

/// Asks the audiobook catalogues about books the tags have been read for and the catalogues have
/// not: Audible's search by title and author, Apple Books when Audible has nothing, Audnexus for
/// the detail of the hit taken. A clear best hit is applied; anything less leaves the book as the
/// names and tags had it, with Fix match for the listener. One book at a time, after the tags.
@MainActor
enum AudiobookMetadata {
    static let lookup = AudiobookLookup(region: "uk")
    private static var running = false

    static func lookupPending(library: LibraryStore) {
        guard !running else { return }
        let pending = library.booksNeedingLookup()
        guard !pending.isEmpty else { return }
        running = true
        Diagnostics.log("library", "looking up \(pending.count) audiobooks in the catalogues")
        Task {
            defer { running = false }
            for book in pending {
                guard DeviceConditions.allowsBackgroundWork, !book.isDeleted else { break }
                let hits = await lookup.search(title: book.title, author: book.author)
                if let best = AudiobookLookup.best(hits, title: book.title, author: book.author) {
                    let full = await lookup.details(best)
                    library.applyBookLookup(book, hit: full, manual: false)
                    Diagnostics.log("library", "catalogue: \(book.title.prefix(40)) → \(full.source) \(full.asin ?? "") \"\(full.title)\" by \(full.authorLine ?? "?")\(full.series.map { ", \($0) \(full.seriesPosition ?? "")" } ?? "")")
                } else {
                    library.markBookUnmatched(book)
                    Diagnostics.log("library", "catalogue: nothing close for \(book.title.prefix(40)) by \(book.author ?? "?") (\(hits.count) hits)")
                }
            }
        }
    }
}
