import XCTest
@testable import WoodruffKit

/// A film's picture times rounded to the millisecond (42, 41, 42 ms apart for 24 frames a second) are put back on
/// the film's own beat, a whole frame apart, moving none of them by more than the rounding; even times stay as they are.
final class FilmFrameGridTests: XCTestCase {
    func testTheRatesFilmsAreMadeAt() {
        XCTAssertEqual(FilmFrameGrid.step(fps: 23.999, shortest: 0.041)?.value, 1000)
        XCTAssertEqual(FilmFrameGrid.step(fps: 23.976, shortest: 0)?.value, 1001)
        XCTAssertEqual(FilmFrameGrid.step(fps: 25, shortest: 0)?.value, 960)
        XCTAssertEqual(FilmFrameGrid.step(fps: 59.94, shortest: 0)?.timescale, 60000)
        XCTAssertNil(FilmFrameGrid.step(fps: 27.3, shortest: 0))
        XCTAssertNil(FilmFrameGrid.step(fps: 0, shortest: 0))
    }

    func testRoundedTimesComeBackAFrameApart() {
        let even = FilmFrameGrid.Evener(value: 1000, timescale: 24000)
        // In the order they're decoded (frames stored out of order), from a start that isn't on a whole frame.
        let order = [0, 4, 2, 1, 3, 8, 6, 5, 7]
        var all: [Int64] = []
        for group in 0..<2000 {
            for o in order {
                let n = group * 9 + o
                let file = ((0.0625 + Double(n) / 24) * 1000).rounded() / 1000
                guard let at = even.even(file) else { return XCTFail("frame \(n) not evened") }
                XCTAssertTrue(at.onBeat)
                XCTAssertLessThanOrEqual(abs(Double(at.at) / 24000 - file), 0.0011)
                all.append(at.at)
            }
        }
        all.sort()
        for (a, b) in zip(all, all.dropFirst()) { XCTAssertEqual(b - a, 1000) }
        XCTAssertGreaterThan(even.moved, 0)
        XCTAssertEqual(even.restarted, 0)
        XCTAssertEqual(even.words, "1/24 s")
    }

    func testEvenTimesStayAsTheyAre() {
        let even = FilmFrameGrid.Evener(value: 1001, timescale: 24000)
        for n in 0..<5000 { XCTAssertEqual(even.even(Double(n * 1001) / 24000)?.at, Int64(n * 1001)) }
        XCTAssertEqual(even.moved, 0)
        XCTAssertEqual(even.words, "1001/24000 s")
    }

    func testAFilmOffItsRateIsNeverMovedFar() {
        let even = FilmFrameGrid.Evener(value: 1000, timescale: 24000)
        for n in 0..<100_000 {
            let file = (Double(n) / 23.999 * 1000).rounded() / 1000
            guard let at = even.even(file) else { return XCTFail("frame \(n) not evened") }
            XCTAssertLessThanOrEqual(abs(Double(at.at) / 24000 - file), 0.0031)
        }
        XCTAssertGreaterThan(even.restarted, 0)
    }
}
