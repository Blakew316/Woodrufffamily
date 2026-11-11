import XCTest
@testable import WoodruffKit

final class StreamKeepTests: XCTestCase {
    private let mb: Int64 = 1 << 20

    /// A 64 MB part starting [at] megabytes into the film.
    private func part(_ at: Int64, used: Double, busy: Bool = false) -> StreamKeep.Part {
        StreamKeep.Part(offset: at * mb, length: 64 * mb, used: used, busy: busy)
    }

    func testNothingGoesWithinTheBudget() {
        let parts = [part(0, used: 1), part(64, used: 2), part(128, used: 3)]
        XCTAssertEqual(StreamKeep.letGo(parts, places: [70 * mb], budget: 192 * mb), [])
    }

    func testWithNoPlaceKnownTheOnesReadLongestAgoGo() {
        let parts = [part(0, used: 5), part(64, used: 1), part(128, used: 3), part(192, used: 4)]
        XCTAssertEqual(StreamKeep.letGo(parts, places: [], budget: 128 * mb), [1, 2])
    }

    func testWhatTheFilmHasPassedGoesBeforeWhatIsAhead() {
        // Reading in the third part; the fourth was fetched ahead long ago and never read.
        let parts = [part(0, used: 10), part(64, used: 20), part(128, used: 30), part(192, used: 1)]
        XCTAssertEqual(StreamKeep.letGo(parts, places: [130 * mb], budget: 128 * mb), [0, 1])
    }

    /// Two places at once, as a film with its sound stored apart from its picture is read. The old rule (read longest
    /// ago first) threw away the part each had fetched ahead.
    func testTwoPlacesBothKeepWhatTheyFetchedAhead() {
        let parts = [
            part(1000, used: 100),            // the picture's last part, just left
            part(1064, used: 101, busy: true), // the picture's part, being read
            part(1128, used: 50),             // fetched ahead for the picture, not read yet
            part(9000, used: 99),             // the sound's part
            part(9064, used: 10),             // fetched ahead for the sound long ago, not read yet
        ]
        let places = [1070 * mb, 9010 * mb]
        // Room for four: only the part the picture has left goes.
        XCTAssertEqual(StreamKeep.letGo(parts, places: places, budget: 256 * mb), [0])
        // And it is the first to go however little room there is.
        XCTAssertEqual(StreamKeep.letGo(parts, places: places, budget: 192 * mb).first, 0)
    }

    /// One reader far ahead of another in the same stretch (picture buffered a minute ahead, sound ten seconds): what
    /// lies between them is the slower one's, and what it comes to last goes first.
    func testBetweenTwoReadersTheFurthestFromTheSlowerOneGoesFirst() {
        let parts = (0..<8).map { part(Int64($0) * 64, used: Double($0)) }   // 0 … 512 MB, read in order
        let places = [10 * mb, 400 * mb]   // the slower in part 0, the faster in part 6
        // Two must go: the two just behind the faster reader, the further from the slower first.
        XCTAssertEqual(StreamKeep.letGo(parts, places: places, budget: 384 * mb), [5, 4])
    }

    func testABusyPartNeverGoes() {
        let parts = [part(0, used: 1, busy: true), part(64, used: 2, busy: true), part(128, used: 3)]
        XCTAssertEqual(StreamKeep.letGo(parts, places: [200 * mb], budget: 64 * mb), [2])
    }

    func testThePartAPlaceIsInGoesLast() {
        let parts = [part(0, used: 9), part(64, used: 1), part(128, used: 5)]
        // Places in the first and the third: the second, ahead of one of them, goes before either.
        XCTAssertEqual(StreamKeep.letGo(parts, places: [10 * mb, 130 * mb], budget: 64 * mb), [1, 2])
    }

    func testALittleBehindAPlaceStillCountsAsWhereItIs() {
        // The reader stands exactly where the first part ends, and may ask again from a little before.
        let parts = [part(0, used: 1), part(64, used: 2), part(128, used: 3)]
        XCTAssertEqual(StreamKeep.letGo(parts, places: [64 * mb], budget: 128 * mb, back: 8 * mb), [2])
        // Without that allowance the first part is simply behind it, and goes.
        XCTAssertEqual(StreamKeep.letGo(parts, places: [64 * mb], budget: 128 * mb), [0])
    }

    func testPlacesCloseTogetherCountAsOne() {
        let near = 16 * mb
        XCTAssertEqual(StreamKeep.places([], near: near).count, 0)
        XCTAssertEqual(StreamKeep.places([5 * mb], near: near).count, 1)
        let one = StreamKeep.places([5 * mb, 12 * mb, 20 * mb], near: near)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.spread, 0)
        let two = StreamKeep.places([900 * mb, 5 * mb, 12 * mb], near: near)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.spread, 895 * mb)
    }

    func testByteRangesCountWhatWasAskedBefore() {
        var r = ByteRanges()
        XCTAssertEqual(r.add(0, 100), 0)
        XCTAssertEqual(r.add(100, 200), 0)          // carries straight on: nothing twice
        XCTAssertEqual(r.spans.count, 1)
        XCTAssertEqual(r.add(150, 250), 50)         // half of it had been asked for
        XCTAssertEqual(r.add(1000, 1100), 0)
        XCTAssertEqual(r.spans.count, 2)
        XCTAssertEqual(r.add(0, 2000), 350)         // all of both runs again
        XCTAssertEqual(r.spans.count, 1)
        XCTAssertEqual(r.total, 2000)
        XCTAssertEqual(r.add(500, 500), 0)          // nothing asked
        XCTAssertEqual(r.add(1999, 2001), 1)
        XCTAssertEqual(r.total, 2001)
    }

    func testByteRangesKeepTheirOrder() {
        var r = ByteRanges()
        r.add(500, 600)
        r.add(100, 200)
        r.add(300, 400)
        XCTAssertEqual(r.spans.map(\.lo), [100, 300, 500])
        XCTAssertEqual(r.add(150, 550), 50 + 100 + 50)
        XCTAssertEqual(r.spans.map(\.lo), [100])
        XCTAssertEqual(r.spans.map(\.hi), [600])
    }
}
