import XCTest
@testable import MediaCore

final class AudiobookGrouperTests: XCTestCase {
    func testSingleFileBooksInASeriesFolder() {
        let root = "Torrents/Books"
        let folder = root + "/The Long Earth (Stephen Baxter & Terry Pratchett)"
        let files = ["02 The Long War.m4b", "01 The Long Earth.m4b", "03 The Long Mars.m4b"].map { folder + "/" + $0 }
        let books = AudiobookGrouper.books(files: files, root: root)
        XCTAssertEqual(books.map(\.title), ["The Long Earth", "The Long War", "The Long Mars"])
        XCTAssertEqual(books[0].author, "Stephen Baxter & Terry Pratchett")
        XCTAssertEqual(books[0].series, "The Long Earth")
        XCTAssertEqual(books[1].seriesIndex, 2)
        XCTAssertEqual(books[0].parts.count, 1)
        XCTAssertEqual(books[0].path, folder + "/01 The Long Earth.m4b")
    }

    func testAFolderOfPartsIsOneBook() {
        let root = "Torrents"
        let folder = root + "/Elizabeth Moon - Remnant Population 2021"
        let files = (1...12).reversed().map { folder + "/Remnant Population-Part\(String(format: "%02d", $0)).mp3" }
        let books = AudiobookGrouper.books(files: files, root: root)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Remnant Population")
        XCTAssertEqual(books[0].author, "Elizabeth Moon")
        XCTAssertEqual(books[0].year, 2021)
        XCTAssertEqual(books[0].parts.map(\.title).prefix(3), ["Part 1", "Part 2", "Part 3"])
        XCTAssertEqual(books[0].parts.last?.relativePath, folder + "/Remnant Population-Part12.mp3")
    }

    func testHalvesOfABookInASeriesAreMerged() {
        let root = "Torrents"
        let series = root + "/SPEC -- Elizabeth Moon – Serrano Legacy 1-7 [Graphic Audio]"
        var files: [String] = []
        for (i, book) in ["01 Hunting Party", "02 Sporting Chance"].enumerated() {
            for half in 1...2 { for p in 1...3 { files.append("\(series)/\(book) \(half) of 2/SL0\(i + 1)0\(half)P0\(p).mp3") } }
        }
        let books = AudiobookGrouper.books(files: files, root: root)
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].title, "Hunting Party")
        XCTAssertEqual(books[0].seriesIndex, 1)
        XCTAssertEqual(books[0].author, "Elizabeth Moon")
        XCTAssertEqual(books[0].series, "Serrano Legacy 1-7")
        XCTAssertEqual(books[0].parts.count, 6)
        XCTAssertEqual(books[0].parts.map(\.relativePath).prefix(4).map { ($0 as NSString).lastPathComponent }, ["SL0101P01.mp3", "SL0101P02.mp3", "SL0101P03.mp3", "SL0102P01.mp3"])
        XCTAssertEqual(books[0].parts.map(\.title).prefix(2), ["Part 1", "Part 2"])
    }

    func testNameParsing() {
        XCTAssertEqual(AudiobookGrouper.parseBookName("Elizabeth Moon - Remnant Population 2021"), .init(title: "Remnant Population", author: "Elizabeth Moon", index: nil, year: 2021))
        XCTAssertEqual(AudiobookGrouper.parseBookName("The Long Earth (Stephen Baxter & Terry Pratchett)").author, "Stephen Baxter & Terry Pratchett")
        XCTAssertEqual(AudiobookGrouper.parseBookName("04 The Long Utopia").index, 4)
        XCTAssertEqual(AudiobookGrouper.parseBookName("SPEC -- Elizabeth Moon – Serrano Legacy 1-7 [Graphic Audio]").title, "Serrano Legacy 1-7")
        XCTAssertEqual(AudiobookGrouper.parseBookName("Project Hail Mary").author, nil)
        XCTAssertEqual(AudiobookGrouper.halfOf("01 Hunting Party 2 of 2")?.index, 2)
        XCTAssertNil(AudiobookGrouper.halfOf("Season 1 of the show"))
    }
}
