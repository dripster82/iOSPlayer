import XCTest
@testable import MediaCore

final class UniversesTests: XCTestCase {
    func testMarvelStudiosFilmIsMCUAndMarvel() {
        let u = Universes.universes(studios: ["Marvel Studios", "Walt Disney Pictures"], keywords: ["superhero", "sequel", "marvel cinematic universe"])
        XCTAssertEqual(u, ["Marvel Cinematic Universe", "Marvel"])
    }

    func testRaimiSpiderManIsMarvelButNotMCU() {
        let u = Universes.universes(studios: ["Columbia Pictures", "Marvel Enterprises"], keywords: ["based on comic", "superhero"])
        XCTAssertEqual(u, ["Marvel"])
    }

    func testGenericStudiosAndKeywordsMakeNoUniverse() {
        XCTAssertEqual(Universes.universes(studios: ["Warner Bros. Pictures", "Legendary Pictures"], keywords: ["sequel", "action"]), [])
    }

    func testKeywordCaseAndSpacingAreForgiven() {
        XCTAssertEqual(Universes.universes(studios: [], keywords: [" Star Wars "]), ["Star Wars"])
        XCTAssertEqual(Universes.universes(studios: ["PIXAR"], keywords: []), ["Pixar"])
    }

    func testLucasfilmIsNotStarWars() {
        XCTAssertEqual(Universes.universes(studios: ["Lucasfilm Ltd."], keywords: ["indiana jones", "archaeologist"]), ["Lucasfilm", "Indiana Jones"])
        XCTAssertEqual(Universes.universes(studios: ["Lucasfilm Ltd."], keywords: ["star wars"]), ["Lucasfilm", "Star Wars"])
    }
    func testNoDuplicates() {
        XCTAssertEqual(Universes.universes(studios: ["Pixar"], keywords: ["toy story", "toy story"]), ["Pixar", "Toy Story"])
    }
}
