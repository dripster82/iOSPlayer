import XCTest
@testable import Metadata

final class AudiobookLookupTests: XCTestCase {
    private func tempCache() -> MetadataCache {
        MetadataCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), ttl: 60)
    }

    private let audibleJSON = #"""
    {"products":[
      {"asin":"B00IX18B4A","title":"The Long Mars","subtitle":"(Long Earth 3)",
       "authors":[{"asin":"B000APWC7Y","name":"Stephen Baxter"},{"asin":"B000AQ0NN8","name":"Terry Pratchett"}],
       "narrators":[{"name":"Michael Fenton Stevens"}],
       "series":[{"asin":"B00HQ4BQLK","sequence":"3","title":"The Long Earth"}],
       "release_date":"2014-06-19","runtime_length_min":723,
       "product_images":{"500":"https://m.media-amazon.com/images/I/51sj8Te8iZL._SL500_.jpg","1000":"https://m.media-amazon.com/images/I/51sj8Te8iZL._SL1000_.jpg"},
       "publisher_name":"Transworld Digital","publisher_summary":"<p>Mars &amp; beyond.<br/>A tale.</p>"},
      {"asin":"B008646FZ6","title":"The Long Earth","subtitle":"The astonishing number one bestseller",
       "authors":[{"name":"Terry Pratchett"},{"name":"Stephen Baxter"}],"narrators":[{"name":"Michael Fenton Stevens"}],
       "series":[{"sequence":"1","title":"The Long Earth"}],"release_date":"2012-06-21","runtime_length_min":690,
       "product_images":{"500":"https://m.media-amazon.com/images/I/51fNpFSZRmL._SL500_.jpg"}}
    ]}
    """#

    func testAudibleProductsBecomeHits() async throws {
        let t = QueryTransport()
        t.responses.append(("catalog/products?title=The Long Earth", Data(audibleJSON.utf8)))
        let client = AudibleCatalogClient(region: "uk", transport: t, cache: tempCache())
        let hits = try await client.search(title: "The Long Earth", author: "Terry Pratchett")
        XCTAssertEqual(hits.count, 2)
        let mars = hits[0]
        XCTAssertEqual(mars.asin, "B00IX18B4A")
        XCTAssertNil(mars.subtitle, "a subtitle that only repeats the series is dropped")
        XCTAssertEqual(mars.authors, ["Stephen Baxter", "Terry Pratchett"])
        XCTAssertEqual(mars.narratorLine, "Michael Fenton Stevens")
        XCTAssertEqual(mars.series, "The Long Earth"); XCTAssertEqual(mars.seriesIndex, 3)
        XCTAssertEqual(mars.year, 2014); XCTAssertEqual(mars.runtimeMinutes, 723)
        XCTAssertEqual(mars.coverURL, "https://m.media-amazon.com/images/I/51sj8Te8iZL._SL1000_.jpg", "the largest image offered")
        XCTAssertEqual(mars.summary, "Mars & beyond.\nA tale.")
        XCTAssertEqual(hits[1].subtitle, "The astonishing number one bestseller")
        XCTAssertTrue(t.calls[0].host?.hasSuffix("audible.co.uk") ?? false)
        XCTAssertTrue(t.calls[0].query?.contains("author=Terry") ?? false)
    }

    func testAppleBooksIsTheFallback() async throws {
        let t = QueryTransport()
        t.responses.append(("catalog/products", Data(#"{"products":[]}"#.utf8)))
        t.responses.append(("itunes.apple.com", Data(#"""
        {"results":[{"wrapperType":"audiobook","collectionId":1646718449,"artistName":"Elizabeth Moon","collectionName":"Remnant Population: A Novel",
          "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg","releaseDate":"2021-01-05T08:00:00Z","primaryGenreName":"Sci-Fi & Fantasy","description":"For forty years…"}]}
        """#.utf8)))
        let lookup = AudiobookLookup(audible: AudibleCatalogClient(transport: t, cache: tempCache()), audnexus: AudnexusClient(transport: t, cache: tempCache()), apple: AppleBooksClient(transport: t, cache: tempCache()))
        let hits = await lookup.search(title: "Remnant Population", author: "Elizabeth Moon")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].source, "Apple Books")
        XCTAssertEqual(hits[0].appleID, 1646718449)
        XCTAssertEqual(hits[0].authors, ["Elizabeth Moon"])
        XCTAssertEqual(hits[0].coverURL, "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg")
        XCTAssertEqual(hits[0].year, 2021)
        XCTAssertEqual(t.calls.filter { $0.host?.contains("audible") ?? false }.count, 2, "with the author, then the title alone, before Apple")
    }

    func testAudnexusFillsTheDetail() async throws {
        let t = QueryTransport()
        t.responses.append(("audnex.us/books/B008646FZ6", Data(#"""
        {"asin":"B008646FZ6","title":"The Long Earth","authors":[{"name":"Terry Pratchett"}],"narrators":[{"name":"Michael Fenton Stevens"}],
         "genres":[{"name":"Science Fiction & Fantasy","type":"genre"},{"name":"Fantasy","type":"tag"}],
         "image":"https://m.media-amazon.com/images/I/814fy82aXSL.jpg","releaseDate":"2012-06-21T00:00:00.000Z","runtimeLengthMin":690,
         "summary":"<p>The Western Front, 1916.</p>","description":"The Western Front, 1916....","seriesPrimary":{"name":"The Long Earth","position":"1"}}
        """#.utf8)))
        let lookup = AudiobookLookup(audible: AudibleCatalogClient(transport: t, cache: tempCache()), audnexus: AudnexusClient(transport: t, cache: tempCache()), apple: AppleBooksClient(transport: t, cache: tempCache()))
        let thin = AudiobookHit(source: "Audible", asin: "B008646FZ6", title: "The Long Earth", authors: ["Terry Pratchett", "Stephen Baxter"], coverURL: "https://x/500.jpg")
        let full = await lookup.details(thin)
        XCTAssertEqual(full.summary, "The Western Front, 1916.")
        XCTAssertEqual(full.genres, ["Science Fiction & Fantasy"])
        XCTAssertEqual(full.coverURL, "https://x/500.jpg", "the search's cover stands")
        XCTAssertEqual(full.series, "The Long Earth"); XCTAssertEqual(full.seriesIndex, 1)
        XCTAssertEqual(full.authors.count, 2, "the search's authors stand")
        let appleOnly = await lookup.details(AudiobookHit(source: "Apple Books", appleID: 1, title: "X"))
        XCTAssertEqual(appleOnly.title, "X", "no ASIN, nothing to ask Audnexus")
    }

    func testBestHitNeedsTheTitleAndTheAuthor() {
        let earth = AudiobookHit(source: "Audible", asin: "1", title: "The Long Earth", authors: ["Terry Pratchett", "Stephen Baxter"])
        let mars = AudiobookHit(source: "Audible", asin: "2", title: "The Long Mars", authors: ["Terry Pratchett", "Stephen Baxter"])
        let other = AudiobookHit(source: "Audible", asin: "3", title: "The Long Earth", authors: ["Someone Else"])
        XCTAssertEqual(AudiobookLookup.best([mars, earth], title: "The Long Earth", author: "Stephen Baxter & Terry Pratchett")?.asin, "1")
        XCTAssertEqual(AudiobookLookup.best([other, earth], title: "Long Earth", author: "Terry Pratchett")?.asin, "1")
        XCTAssertNil(AudiobookLookup.best([mars], title: "The Long Earth", author: "Terry Pratchett"), "a sibling in the series is not the book")
        XCTAssertNil(AudiobookLookup.best([other], title: "The Long Earth", author: "Terry Pratchett"), "the right title by the wrong author is not taken unasked")
        XCTAssertEqual(AudiobookLookup.best([earth], title: "01 The Long Earth", author: nil)?.asin, "1", "no author known: the title decides")
        XCTAssertEqual(AudiobookLookup.best([AudiobookHit(source: "Apple Books", appleID: 1, title: "Remnant Population: A Novel", authors: ["Elizabeth Moon"])], title: "Remnant Population", author: "Elizabeth Moon")?.appleID, 1)
        XCTAssertEqual(AudiobookHit(source: "x", title: "t", seriesPosition: "1.5").seriesIndex, nil)
        XCTAssertEqual(AudiobookHit(source: "x", title: "t", seriesPosition: "4.0").seriesIndex, 4)
    }
}
