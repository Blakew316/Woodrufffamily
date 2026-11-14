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

    func testItWaitsALittleBeforeTheLastOfItHasGone() {
        let move = FilmBuffering.move(waiting: false, picture: 0.2, sound: 3, pictureDone: false, soundDone: false, enough: 2, low: 0.25)
        XCTAssertEqual(move, .wait)
        let fine = FilmBuffering.move(waiting: false, picture: 0.3, sound: 3, pictureDone: false, soundDone: false, enough: 2, low: 0.25)
        XCTAssertEqual(fine, .stay)
    }

    /// The picture waits a moment earlier than the sound: a frame that reaches the decoder only as it's due is shown
    /// late or not at all (a fast stutter), where a short wait isn't.
    func testThePictureWaitsBeforeItsLastSecond() {
        func move(_ p: Double, _ s: Double) -> FilmBuffering.Move {
            FilmBuffering.move(waiting: false, picture: p, sound: s, pictureDone: false, soundDone: false, enough: 2.5, low: 0.25, pictureLow: 1)
        }
        XCTAssertEqual(move(0.8, 5), .wait)
        XCTAssertEqual(move(1.5, 5), .stay)
        // The sound keeps its own: half a second of it is still plenty.
        XCTAssertEqual(move(5, 0.5), .stay)
        XCTAssertEqual(move(5, 0.2), .wait)
        // All of the picture read: nothing to wait for.
        XCTAssertEqual(FilmBuffering.move(waiting: false, picture: 0.1, sound: 5, pictureDone: true, soundDone: false, enough: 2.5, low: 0.25, pictureLow: 1), .stay)
    }

    func testSubtitleWords() {
        // As the test film has them: two bytes of length, then the words.
        XCTAssertEqual(FilmText.subtitle(Data([0x00, 0x0a] + Array("First line".utf8))), "First line")
        // A gap between two lines.
        XCTAssertNil(FilmText.subtitle(Data([0x00, 0x00])))
        XCTAssertNil(FilmText.subtitle(Data()))
        // What follows the words (their styling) is left.
        XCTAssertEqual(FilmText.subtitle(Data([0x00, 0x02] + Array("Hi".utf8) + [0, 0, 0, 12, 0x73, 0x74, 0x79, 0x6c])), "Hi")
        // A length that runs past the sample says nothing.
        XCTAssertNil(FilmText.subtitle(Data([0x00, 0x09] + Array("Hi".utf8))))
        // Two bytes a letter, when it starts with the mark that says so.
        XCTAssertEqual(FilmText.subtitle(Data([0x00, 0x06, 0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])), "Hi")
        XCTAssertEqual(FilmText.subtitle(Data([0x00, 0x05] + Array("  Hi\n".utf8))), "Hi")
    }

    func testAFilmsTimeAsItsPlayerShowsIt() {
        XCTAssertEqual(FilmText.clock(7, hours: false), "0:07")
        XCTAssertEqual(FilmText.clock(123.9, hours: false), "2:03")
        XCTAssertEqual(FilmText.clock(8621, hours: true), "2:23:41")
        XCTAssertEqual(FilmText.clock(59, hours: true), "0:00:59")
        XCTAssertEqual(FilmText.clock(3723, hours: false), "1:02:03")
        XCTAssertEqual(FilmText.clock(-4, hours: false), "0:00")
        XCTAssertEqual(FilmText.clock(.nan, hours: false), "0:00")
    }
}
