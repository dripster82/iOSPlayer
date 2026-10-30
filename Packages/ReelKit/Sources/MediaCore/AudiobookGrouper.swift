import Foundation

/// Turns the audio files under an audiobooks folder into books. Three shapes are common and all
/// three are read:
///  - a folder of single-file books ("01 The Long Earth.m4b", "02 The Long War.m4b"): one book per
///    file, the folder is the series and names the author in brackets or before a dash;
///  - a book as a folder of parts ("Remnant Population-Part01.mp3" …): one book, the parts in
///    order, author and title from the folder name ("Author - Title 2021");
///  - a series of per-book folders, each possibly split ("01 Hunting Party 1 of 2", "… 2 of 2"):
///    the halves are one book, the parts of the first half before the second.
/// Embedded tags (title, author, cover) are read later and override what the names gave.
public enum AudiobookGrouper {
    public struct Part: Equatable, Sendable {
        public var relativePath: String
        public var title: String
        public init(relativePath: String, title: String) { self.relativePath = relativePath; self.title = title }
    }
    public struct Book: Equatable, Sendable {
        /// The folder (or single file) that is the book, relative to the source: the book's identity.
        public var path: String
        public var title: String
        public var author: String?
        public var series: String?
        public var seriesIndex: Int?
        public var year: Int?
        public var parts: [Part]
        public init(path: String, title: String, author: String? = nil, series: String? = nil, seriesIndex: Int? = nil, year: Int? = nil, parts: [Part]) {
            self.path = path; self.title = title; self.author = author; self.series = series; self.seriesIndex = seriesIndex; self.year = year; self.parts = parts
        }
    }

    /// `files` are the audio files' paths relative to the source, all under `root` (the tagged folder).
    public static func books(files: [String], root: String) -> [Book] {
        let byFolder = Dictionary(grouping: files) { ($0 as NSString).deletingLastPathComponent }
        var books: [Book] = []
        var merged = Set<String>()
        for (folder, paths) in byFolder.sorted(by: { $0.key < $1.key }) where !merged.contains(folder) {
            let names = paths.map { ($0 as NSString).lastPathComponent }
            let folderName = (folder as NSString).lastPathComponent
            let parentName = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let isRoot = folder == root || folder.isEmpty
            if partsOfOneBook(names) && !isRoot {
                // A folder of parts. Its siblings "X 2 of 2" (and so on) belong to the same book.
                var all = paths
                var bookFolderName = folderName
                if let (stem, index) = halfOf(folderName), index == 1 {
                    bookFolderName = stem
                    for (other, otherPaths) in byFolder where other != folder && (other as NSString).deletingLastPathComponent == (folder as NSString).deletingLastPathComponent {
                        if let (s2, _) = halfOf((other as NSString).lastPathComponent), s2 == stem { all += otherPaths; merged.insert(other) }
                    }
                } else if halfOf(folderName) != nil { continue }   // a later half: picked up with the first
                merged.insert(folder)
                let named = parseBookName(bookFolderName)
                let fromParent = isSeriesFolder(parentName, root: root, folder: folder) ? parseBookName(parentName) : nil
                let ordered = all.sorted { naturalLess(($0 as NSString).lastPathComponent, ($1 as NSString).lastPathComponent) }
                books.append(Book(path: folder, title: named.title, author: named.author ?? fromParent?.author, series: fromParent?.title,
                                  seriesIndex: named.index, year: named.year,
                                  parts: ordered.enumerated().map { Part(relativePath: $1, title: partTitle(($1 as NSString).lastPathComponent, index: $0 + 1)) }))
            } else {
                // Single-file books, the folder being a series (or the root).
                let series = isRoot ? nil : parseBookName(folderName)
                for p in paths.sorted(by: { naturalLess(($0 as NSString).lastPathComponent, ($1 as NSString).lastPathComponent) }) {
                    let stem = (((p as NSString).lastPathComponent) as NSString).deletingPathExtension
                    let named = parseBookName(stem)
                    books.append(Book(path: p, title: named.title, author: named.author ?? series?.author, series: series?.title, seriesIndex: named.index, year: named.year,
                                      parts: [Part(relativePath: p, title: named.title)]))
                }
            }
        }
        return books.sorted { ($0.series ?? "", $0.seriesIndex ?? 0, $0.title) < ($1.series ?? "", $1.seriesIndex ?? 0, $1.title) }
    }

    /// Files that are parts of one recording rather than separate books: numbered parts, discs or
    /// tracks that share a stem, or several files whose names differ only by a number.
    static func partsOfOneBook(_ names: [String]) -> Bool {
        guard names.count >= 2 else {
            // One file in a folder of its own is a book of one part when the folder names it.
            return names.count == 1 && names[0].range(of: #"(?i)(part|pt|disc|disk|cd|chapter|ch|track)\s*[-_ ]?\d+"#, options: .regularExpression) != nil
        }
        let stems = names.map { stemWithoutNumbers($0) }
        return Set(stems).count == 1 || names.allSatisfy { $0.range(of: #"(?i)(part|pt|disc|disk|cd|chapter|ch|track)\s*[-_ ]?\d+"#, options: .regularExpression) != nil }
    }

    static func stemWithoutNumbers(_ name: String) -> String {
        var s = ((name as NSString).deletingPathExtension).lowercased()
        s = s.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        return s.replacingOccurrences(of: #"[\s_\-\.]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// "Hunting Party 1 of 2" → ("Hunting Party", 1).
    static func halfOf(_ folderName: String) -> (stem: String, index: Int)? {
        guard let m = folderName.range(of: #"(?i)\s*[\(\[]?\s*(part\s*)?(\d+)\s*(of|/)\s*(\d+)\s*[\)\]]?\s*$"#, options: .regularExpression) else { return nil }
        let tail = String(folderName[m])
        let digits = tail.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        guard let first = digits.first, let index = Int(first) else { return nil }
        return (String(folderName[..<m.lowerBound]).trimmingCharacters(in: .whitespaces), index)
    }

    /// Whether the folder above a book's folder is a series folder rather than the tagged root.
    static func isSeriesFolder(_ parentName: String, root: String, folder: String) -> Bool {
        let parent = (folder as NSString).deletingLastPathComponent
        return parent != root && !parent.isEmpty && !parentName.isEmpty
    }

    public struct ParsedName: Equatable, Sendable { public var title: String; public var author: String?; public var index: Int?; public var year: Int? }

    /// "01 The Long Earth" → index 1; "Elizabeth Moon - Remnant Population 2021" → author, title,
    /// year; "The Long Earth (Stephen Baxter & Terry Pratchett)" → title, author; bracketed tags such
    /// as "[Graphic Audio]" or "SPEC --" prefixes are dropped.
    public static func parseBookName(_ raw: String) -> ParsedName {
        var s = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*[A-Z]{2,6}\s*-{1,2}\s*"#, with: "", options: .regularExpression)   // "SPEC -- "
        s = s.replacingOccurrences(of: "_", with: " ")
        var index: Int?
        if let m = s.range(of: #"^\s*(\d{1,3})\s*[-–.)]?\s+"#, options: .regularExpression) {
            index = Int(s[m].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)); s.removeSubrange(m)
        }
        var year: Int?
        if let m = s.range(of: #"[\(\s](19|20)\d{2}[\)\s]*$"#, options: .regularExpression) {
            year = Int(s[m].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)); s.removeSubrange(m)
        }
        var author: String?
        if let m = s.range(of: #"\(([^)]+)\)\s*$"#, options: .regularExpression) {
            let inside = s[m].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if looksLikeAuthor(inside) { author = inside; s.removeSubrange(m) }
        }
        if author == nil, let dash = s.range(of: #"\s+[-–—]+\s+"#, options: .regularExpression) {
            let left = String(s[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces), right = String(s[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if looksLikeAuthor(left), !right.isEmpty { author = left; s = right }
            else if looksLikeAuthor(right), !left.isEmpty, right.split(separator: " ").count <= 4 { author = right; s = left }
        }
        s = s.replacingOccurrences(of: #"\s+(\d+)\s*(of|/)\s*\d+\s*$"#, with: "", options: .regularExpression)
        let title = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–.")))
        return ParsedName(title: title.isEmpty ? raw : title, author: author, index: index, year: year)
    }

    /// Two to four capitalised words, "&" or "and" between names allowed, no digits: a person, not a title.
    static func looksLikeAuthor(_ s: String) -> Bool {
        let names = s.replacingOccurrences(of: #"\s*(&|,|\band\b)\s*"#, with: "|", options: .regularExpression).split(separator: "|")
        guard !names.isEmpty, names.count <= 3, s.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        return names.allSatisfy { n in
            let words = n.split(separator: " ")
            return (2...4).contains(words.count) && words.allSatisfy { $0.first?.isUppercase == true || $0.count <= 3 }
        }
    }

    /// "Remnant Population-Part03" → "Part 3"; "SL0101P02" → "Part 2"; otherwise the stem.
    static func partTitle(_ fileName: String, index: Int) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        if let m = stem.range(of: #"(?i)(part|pt|chapter|ch|disc|cd|track)\s*[-_ ]?0*(\d+)\s*$"#, options: .regularExpression) {
            let word = stem[m].lowercased().hasPrefix("ch") ? "Chapter" : stem[m].lowercased().hasPrefix("disc") || stem[m].lowercased().hasPrefix("cd") ? "Disc" : "Part"
            if let n = Int(stem[m].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) { return "\(word) \(n)" }
        }
        if stem.range(of: #"(?i)P0*\d+$"#, options: .regularExpression) != nil { return "Part \(index)" }
        return stem
    }

    static func naturalLess(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending }
}
