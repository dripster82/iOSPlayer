import SwiftUI
import MediaCore
import Library

/// Audiobooks: every book the scan found, in series order, as a list with cover, author and how
/// far along it is. Appears in the sidebar and the Files tab only once there is a book.
struct AudiobooksView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var refresh = 0

    var body: some View {
        let books = library.audiobooks()
        let _ = refresh
        List {
            if books.isEmpty {
                ContentUnavailableView("No audiobooks yet", systemImage: "headphones", description: Text("Tag a folder as Audiobooks on a source (Settings → Libraries → the source → its folders) and scan. One m4b per book, or a folder of parts, both work."))
            }
            ForEach(groupedBySeries(books), id: \.name) { group in
                Section {
                    ForEach(group.books, id: \.itemKey) { book in
                        NavigationLink(value: book.itemKey) { BookRow(book: book) }
                    }
                } header: { if let n = group.name { Text(n) } }
            }
        }
        .navigationTitle("Audiobooks")
        .itemNavigation()
        .onReceive(library.objectWillChange) { _ in refresh += 1 }
    }

    private struct SeriesGroup { let name: String?; let books: [MediaItem] }
    private func groupedBySeries(_ books: [MediaItem]) -> [SeriesGroup] {
        var order: [String?] = []
        var byName: [String?: [MediaItem]] = [:]
        for b in books {
            let key = b.seriesName
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(b)
        }
        // Books without a series come last, under no header.
        return order.filter { $0 != nil }.map { SeriesGroup(name: $0, books: byName[$0]!) } + (byName[nil].map { [SeriesGroup(name: nil, books: $0)] } ?? [])
    }
}

/// One book in a list: cover, title, author, length or progress.
struct BookRow: View {
    @EnvironmentObject private var library: LibraryStore
    let book: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            BookCover(book: book).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.seriesIndex.map { "\($0). " } ?? "" + book.title).font(.body.weight(.semibold)).lineLimit(2)
                if let a = book.author { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                Text(BookProgress.summary(book, library: library)).font(.caption).foregroundStyle(.secondary)
                if let p = BookProgress.fraction(book, library: library) { ProgressView(value: p).tint(Color.accentColor) }
            }
        }
    }
}

/// The cover from the file's tags or a picture beside it, else a generic card with the first letters.
struct BookCover: View {
    let book: MediaItem
    var body: some View {
        if let url = LibraryStore.coverURL(book) {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else { placeholder.clipShape(RoundedRectangle(cornerRadius: 8)) }
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55), Color(hue: hue, saturation: 0.6, brightness: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "headphones").font(.title2).foregroundStyle(.white.opacity(0.85))
        }
    }
    private var hue: Double { Double(abs(book.title.hashValue % 360)) / 360 }
}

/// Progress across a book's parts, from the parts' watch states.
@MainActor enum BookProgress {
    static func parts(_ book: MediaItem) -> [MediaItem] {
        book.episodes.filter { !$0.files.isEmpty && !$0.pendingDeletion }.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }
    /// Seconds listened and the whole length, when every part's length is known (it is once each has played or probed).
    static func listened(_ book: MediaItem, library: LibraryStore) -> (done: TimeInterval, total: TimeInterval, known: Bool) {
        var done: TimeInterval = 0, total: TimeInterval = 0, known = true
        for p in parts(book) {
            let ws = library.watchState(p.itemKey)
            let length = ws?.duration.nonZero ?? p.files.first?.duration ?? 0
            if length == 0 { known = false }
            total += length
            if let ws { done += ws.watched ? length : min(ws.position, length) }
        }
        return (done, total, known)
    }
    static func fraction(_ book: MediaItem, library: LibraryStore) -> Double? {
        let parts = parts(book)
        guard !parts.isEmpty else { return nil }
        let l = listened(book, library: library)
        if l.known, l.total > 0 { return l.done > 0 ? min(1, l.done / l.total) : nil }
        // Lengths unknown: parts finished, plus the fraction of the one in progress.
        var score = 0.0
        for p in parts {
            guard let ws = library.watchState(p.itemKey) else { continue }
            score += ws.watched ? 1 : (ws.progress ?? 0)
        }
        return score > 0 ? min(1, score / Double(parts.count)) : nil
    }
    static func summary(_ book: MediaItem, library: LibraryStore) -> String {
        let parts = parts(book)
        let l = listened(book, library: library)
        var bits: [String] = []
        if l.known, l.total > 0 { bits.append(hours(l.total)) } else { bits.append(parts.count == 1 ? "1 part" : "\(parts.count) parts") }
        if let f = fraction(book, library: library) {
            if f >= 0.99 { bits.append("Finished") }
            else if l.known, l.total > 0 { bits.append("\(hours(l.total - l.done)) left") }
            else { bits.append("\(Int(f * 100))% done") }
        }
        return bits.joined(separator: " · ")
    }
    static func hours(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
    /// The part to play: the one in progress, else the first unfinished, else the first.
    static func next(_ book: MediaItem, library: LibraryStore) -> MediaItem? {
        let parts = parts(book)
        if let going = parts.first(where: { library.watchState($0.itemKey)?.isInProgress == true }) { return going }
        return parts.first { !(library.watchState($0.itemKey)?.watched ?? false) } ?? parts.first
    }
}

private extension TimeInterval { var nonZero: TimeInterval? { self > 0 ? self : nil } }

/// A book's page: cover, title, author, narrator, series, then its parts with a play button each.
struct AudiobookDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    let book: MediaItem
    @State private var refresh = 0
    @State private var confirmReset = false

    var body: some View {
        let parts = BookProgress.parts(book)
        let next = BookProgress.next(book, library: library)
        let _ = refresh
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    BookCover(book: book).frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.title2.weight(.bold))
                        if let a = book.author { Text(a).font(.headline).foregroundStyle(.secondary) }
                        if let n = book.narrator { Text("Read by \(n)").font(.subheadline).foregroundStyle(.secondary) }
                        if let s = book.seriesName { Text(book.seriesIndex.map { "\(s), book \($0)" } ?? s).font(.subheadline).foregroundStyle(.secondary) }
                        if let y = book.year { Text(String(y)).font(.caption).foregroundStyle(.secondary) }
                        Text(BookProgress.summary(book, library: library)).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                if let next {
                    Button {
                        player.play(next, settings: settings)
                    } label: {
                        let ws = library.watchState(next.itemKey)
                        let resuming = ws?.isInProgress == true
                        Label(resuming ? "Resume · \(partLabel(next, of: parts)) at \(MediaFormat.clock(ws?.position ?? 0))" : (parts.count > 1 ? "Play from \(partLabel(next, of: parts))" : "Play"), systemImage: resuming ? "play.fill" : "play")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent)
                }
            }
            Section {
                ForEach(parts, id: \.itemKey) { part in
                    let ws = library.watchState(part.itemKey)
                    Button { player.play(part, settings: settings) } label: {
                        HStack {
                            Image(systemName: ws?.watched == true ? "checkmark.circle.fill" : ws?.isInProgress == true ? "play.circle.fill" : "circle").foregroundStyle(ws?.watched == true ? .green : Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.title).foregroundStyle(.primary)
                                Text(partDetail(part, ws: ws)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let p = ws?.progress, ws?.watched != true { ProgressView(value: p).frame(width: 60) }
                        }
                    }
                    .contextMenu {
                        Button { library.setWatched(!(ws?.watched ?? false), itemKey: part.itemKey); refresh += 1 } label: { Label(ws?.watched == true ? "Mark as unfinished" : "Mark as finished", systemImage: ws?.watched == true ? "circle" : "checkmark.circle") }
                    }
                }
            } header: { Text(parts.count == 1 ? "File" : "Parts") } footer: {
                if let f = parts.first?.files.first, let s = f.source { Text("\(s.name) · \(((f.relativePath as NSString).deletingLastPathComponent))").font(.caption) }
            }
            Section {
                Button("Mark the whole book finished") { library.setWatched(true, itemKeys: parts.map(\.itemKey)); refresh += 1 }
                Button("Start the book over", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Start over?", isPresented: $confirmReset) {
            Button("Forget my place in every part", role: .destructive) {
                library.setWatched(false, itemKeys: parts.map(\.itemKey))
                for p in parts { library.clearProgress(itemKey: p.itemKey) }
                refresh += 1
            }
        }
        .onReceive(library.objectWillChange) { _ in refresh += 1 }
    }

    private func partLabel(_ part: MediaItem, of parts: [MediaItem]) -> String {
        parts.count > 1 ? "part \(part.episodeNumber ?? 0) of \(parts.count)" : "the start"
    }
    private func partDetail(_ part: MediaItem, ws: WatchState?) -> String {
        var bits: [String] = []
        if let d = ws?.duration, d > 0 { bits.append(BookProgress.hours(d)) } else if let d = part.files.first?.duration, d > 0 { bits.append(BookProgress.hours(d)) }
        if let f = part.files.first { bits.append(MediaFormat.bytes(f.size)) }
        if ws?.isInProgress == true, let p = ws?.position { bits.append("at \(MediaFormat.clock(p))") }
        return bits.joined(separator: " · ")
    }
}
