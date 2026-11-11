import XCTest
@testable import WoodruffKit

final class FilmRunsTests: XCTestCase {
    private let kb: Int64 = 1 << 10

    func testSamplesThatFollowOneAnotherAreOneRun() {
        // Five frames back to back, 100 KB each.
        let offsets = (0..<5).map { 1000 + Int64($0) * 100 * kb }
        let sizes = Array(repeating: Int(100 * kb), count: 5)
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 0, most: 4 << 20), 5)
    }

    func testARunStopsAtItsMostBytes() {
        let offsets = (0..<5).map { Int64($0) * 100 * kb }
        let sizes = Array(repeating: Int(100 * kb), count: 5)
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 0, most: Int(250 * kb)), 2)
        // One sample bigger than the most is still a run of its own.
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 0, most: 10), 1)
    }

    /// A film stored the usual way: a little sound sits between two stretches of picture, and is read through.
    func testASmallGapIsReadThrough() {
        let offsets: [Int64] = [0, 100 * kb, 230 * kb]      // 30 KB of sound before the third frame
        let sizes = [Int(100 * kb), Int(100 * kb), Int(100 * kb)]
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 64 * kb, most: 4 << 20), 3)
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 16 * kb, most: 4 << 20), 2)
    }

    /// The film this was written for: its sound 35 GB from its picture. Each track is its own run of runs; nothing
    /// ever spans the two.
    func testAFarJumpStartsANewRun() {
        let far: Int64 = 35 << 30
        let offsets: [Int64] = [0, 100 * kb, far, far + 100 * kb]
        let sizes = Array(repeating: Int(100 * kb), count: 4)
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 256 * kb, most: 4 << 20), 2)
    }

    func testASampleBeforeTheRunStartsANewOne() {
        // Decode order going backwards in the file (it can, between chunks).
        let offsets: [Int64] = [500 * kb, 100 * kb]
        let sizes = [Int(100 * kb), Int(100 * kb)]
        XCTAssertEqual(FilmRuns.count(offsets: offsets, sizes: sizes, gap: 256 * kb, most: 4 << 20), 1)
        XCTAssertEqual(FilmRuns.count(offsets: [], sizes: [], gap: 0, most: 1), 0)
    }

    func testAFilmStartsOnceEnoughOfBothIsReady() {
        let enough = 2.0
        func move(_ waiting: Bool, _ p: Double?, _ s: Double?, pDone: Bool = false, sDone: Bool = false) -> FilmBuffering.Move {
            FilmBuffering.move(waiting: waiting, picture: p, sound: s, pictureDone: pDone, soundDone: sDone, enough: enough)
        }
        XCTAssertEqual(move(true, 0.5, 3), .stay)
        XCTAssertEqual(move(true, 3, 0.5), .stay)
        XCTAssertEqual(move(true, 2, 2), .go)
        // The last seconds of a film: all there is has been read.
        XCTAssertEqual(move(true, 0.4, 0.2, pDone: true, sDone: true), .go)
        // A film with no sound, or no picture.
        XCTAssertEqual(move(true, 2.5, nil), .go)
        XCTAssertEqual(move(true, nil, 2.5), .go)
    }

    func testAFilmWaitsOnlyWhenWhatIsReadyHasRunOut() {
        func move(_ p: Double?, _ s: Double?, pDone: Bool = false, sDone: Bool = false) -> FilmBuffering.Move {
            FilmBuffering.move(waiting: false, picture: p, sound: s, pictureDone: pDone, soundDone: sDone, enough: 2)
        }
        XCTAssertEqual(move(0.3, 0.3), .stay)
        XCTAssertEqual(move(0, 4), .wait)
        XCTAssertEqual(move(4, -0.1), .wait)
        // At the very end nothing more is coming: it plays out.
        XCTAssertEqual(move(0, 0, pDone: true, sDone: true), .stay)
        XCTAssertEqual(move(0, nil, pDone: true), .stay)
    }
}
