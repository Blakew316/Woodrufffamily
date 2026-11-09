import XCTest
@testable import WoodruffKit

final class TitleTextTests: XCTestCase {
    func testYearsComeOff() {
        XCTAssertEqual(TitleText.withoutYear("Vice (2018)"), "Vice")
        XCTAssertEqual(TitleText.withoutYear("Vice 2018"), "Vice")
        XCTAssertEqual(TitleText.withoutYear("Vice.2018.1080p"), "Vice")
        XCTAssertEqual(TitleText.withoutYear("Dune Part Two [2024]"), "Dune Part Two")
        XCTAssertEqual(TitleText.withoutYear("Everest - 2015"), "Everest")
        XCTAssertEqual(TitleText.withoutYear("The.Matrix.1999.1080p.BluRay.x264-GRP"), "The Matrix")
        XCTAssertEqual(TitleText.withoutYear("Ocean's Eleven (2001) [1080p]"), "Ocean's Eleven")
        XCTAssertEqual(TitleText.withoutYear("Up 2009 2160p HEVC"), "Up")
        XCTAssertEqual(TitleText.withoutYear("Friends (1994)"), "Friends")
    }

    func testNumbersInNamesStay() {
        XCTAssertEqual(TitleText.withoutYear("2001: A Space Odyssey"), "2001: A Space Odyssey")
        XCTAssertEqual(TitleText.withoutYear("1917"), "1917")
        XCTAssertEqual(TitleText.withoutYear("1917 (2019)"), "1917")
        XCTAssertEqual(TitleText.withoutYear("Blade Runner 2049"), "Blade Runner 2049")
        XCTAssertEqual(TitleText.withoutYear("Blade Runner 2049 (2017)"), "Blade Runner 2049")
        XCTAssertEqual(TitleText.withoutYear("Zootopia 2"), "Zootopia 2")
        XCTAssertEqual(TitleText.withoutYear("Space: 1999"), "Space: 1999")
        XCTAssertEqual(TitleText.withoutYear("Apollo 13 (1995)"), "Apollo 13")
        XCTAssertEqual(TitleText.withoutYear("(500) Days of Summer (2009)"), "(500) Days of Summer")
        XCTAssertEqual(TitleText.withoutYear("Movie (Part 1) (2018)"), "Movie (Part 1)")
        XCTAssertEqual(TitleText.withoutYear("Vice"), "Vice")
    }

    func testDecodedTitlesShowNoYear() throws {
        let json = #"""
        {"state":"ready","featured":[{"id":"a","kind":"movie","title":"Vice (2018)","year":2018}],
         "continue":[{"key":"k","playTitle":"Vice (2018)","kind":"movie","name":"Vice 2018",
                      "play":{"key":"k","title":"Vice (2018)"}}]}
        """#
        let h = try JSONDecoder().decode(WatchHome.self, from: Data(json.utf8))
        XCTAssertEqual(h.featured?.first?.title, "Vice")
        XCTAssertEqual(h.featured?.first?.year, 2018)
        XCTAssertEqual(h.continue?.first?.name, "Vice")
        // What plays is left as the TV named it.
        XCTAssertEqual(h.continue?.first?.playTitle, "Vice (2018)")
        XCTAssertEqual(h.continue?.first?.play.title, "Vice (2018)")
        // And kept the same way it's read.
        let again = try JSONDecoder().decode(WatchHome.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(again, h)

        let d = try JSONDecoder().decode(TitleDetails.self, from: Data(#"{"id":"a","kind":"movie","title":"Dune Part Two [2024]"}"#.utf8))
        XCTAssertEqual(d.title, "Dune Part Two")
    }
}
