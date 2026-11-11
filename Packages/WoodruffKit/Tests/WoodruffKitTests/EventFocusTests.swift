import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import WoodruffKit

/// Where a camera alert's picture zooms in: on the figure that moved, else on what changed.
final class EventFocusTests: XCTestCase {
    private let w = 64, h = 36

    /// A grid with the cells under each box changed.
    private func grid(_ boxes: [CGRect]) -> [Bool] {
        var g = [Bool](repeating: false, count: w * h)
        for b in boxes {
            for y in 0..<h { for x in 0..<w where b.contains(CGPoint(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h))) { g[y * w + x] = true } }
        }
        return g
    }

    func testWhatChangedBetweenTwoPictures() {
        var a = [UInt8](repeating: 100, count: w * h), b = a
        a[5] = 130; a[6] = 120; b[7] = 60
        let c = EventFocus.changed(a, since: b)
        XCTAssertEqual(c.enumerated().filter { $0.element }.map { $0.offset }, [5, 7], "20 brighter is no change")
        XCTAssertEqual(EventFocus.changed(a, since: [1, 2]), [], "pictures of different sizes")
        XCTAssertEqual(EventFocus.any([grid([CGRect(x: 0, y: 0, width: 0.1, height: 0.1)]), grid([CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)])]).filter { $0 }.count, 48)
    }

    func testThePatchThatChanged() throws {
        // A child crossing the far side of the street (a couple of cells), with a speck of noise elsewhere.
        let child = CGRect(x: 0.125, y: 0.19, width: 0.03, height: 0.06), speck = CGRect(x: 0.8, y: 0.8, width: 0.015, height: 0.02)
        let p = try XCTUnwrap(EventFocus.patch(grid([child, speck]), width: w, height: h))
        XCTAssertTrue(p.intersects(child), "\(p)")
        XCTAssertLessThan(p.width, 0.08)
        XCTAssertLessThan(p.height, 0.12)
        // Nothing, a single cell, or the light (half the picture) is no patch.
        XCTAssertNil(EventFocus.patch(grid([]), width: w, height: h))
        XCTAssertNil(EventFocus.patch(grid([speck]), width: w, height: h))
        XCTAssertNil(EventFocus.patch(grid([CGRect(x: 0, y: 0, width: 1, height: 0.5)]), width: w, height: h))
        XCTAssertNil(EventFocus.patch([true, false], width: w, height: h), "a grid of the wrong size")
        // Two things moved: the bigger one.
        let car = CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.25)
        let both = try XCTUnwrap(EventFocus.patch(grid([child, car]), width: w, height: h))
        XCTAssertTrue(both.intersects(car))
        XCTAssertFalse(both.intersects(child))
    }

    func testTheFigureThatMovedIsTheSubject() throws {
        let walker = CGRect(x: 0.90, y: 0.36, width: 0.05, height: 0.14)
        // A fence post the detector takes for a person, surer than the real one, and never moving.
        let post = CGRect(x: 0.03, y: 0.23, width: 0.02, height: 0.05)
        let found = [(box: post, confidence: 0.99), (box: walker, confidence: 0.45)]
        XCTAssertEqual(EventFocus.subject(found, changed: grid([walker]), width: w, height: h), walker)
        // Not known where the picture changed (no frames kept): the one it's sure of.
        XCTAssertEqual(EventFocus.subject(found, changed: nil, width: w, height: h), post)
        // Something changed, but under neither figure (a car passing): the sure one again.
        XCTAssertEqual(EventFocus.subject(found, changed: grid([CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.1)]), width: w, height: h), post)
        // Two people walking together: one box round both.
        let second = CGRect(x: 0.82, y: 0.38, width: 0.05, height: 0.13)
        let pair = try XCTUnwrap(EventFocus.subject([(box: walker, confidence: 0.6), (box: second, confidence: 0.5)], changed: grid([walker, second]), width: w, height: h))
        XCTAssertEqual(pair, walker.union(second))
        // Two found with nothing known to have moved: an unsure one beside a sure one is left out.
        XCTAssertEqual(EventFocus.subject([(box: walker, confidence: 0.9), (box: second, confidence: 0.4)], changed: nil, width: w, height: h), walker)
        // One unsure figure is still better than none.
        XCTAssertEqual(EventFocus.subject([(box: walker, confidence: 0.36)], changed: nil, width: w, height: h), walker)
        XCTAssertNil(EventFocus.subject([], changed: nil, width: w, height: h))
    }

    // MARK: The moment in a clip

    func testTheSceneIsWhatStaysTheSameThroughAClip() {
        // Five frames of a grey yard (brightness 100); something bright crosses it, one cell a frame.
        var frames = [[UInt8]](repeating: [UInt8](repeating: 100, count: 6), count: 5)
        for i in 0..<5 { frames[i][i] = 230 }
        XCTAssertEqual(EventFocus.scene(frames), [UInt8](repeating: 100, count: 6))
        // Against it, what crossed stands out in each frame, where it was then.
        XCTAssertEqual(EventFocus.changed(frames[3], since: EventFocus.scene(frames)), [false, false, false, true, false, false])
        // Someone already there in the first frame, gone by the third: the first frame is no measure of the scene.
        var leaving = [[UInt8]](repeating: [UInt8](repeating: 100, count: 4), count: 5)
        leaving[0][1] = 20; leaving[1][1] = 20
        XCTAssertEqual(EventFocus.scene(leaving), [100, 100, 100, 100])
        XCTAssertEqual(EventFocus.scene([]), [])
        // A frame of another size is left out.
        XCTAssertEqual(EventFocus.scene([[10, 10], [30, 30], [50, 50], [1]]), [30, 30])
    }

    func testTheFrameOfAClipThatShowsThePerson() throws {
        // Nobody for a second and a half, then someone walks up: largest and surest at 2.8 s.
        let looks = [
            EventFocus.Look(time: 0.0, changed: 0),
            EventFocus.Look(time: 0.4, changed: 0),
            EventFocus.Look(time: 0.8, changed: 0.005),
            EventFocus.Look(time: 1.2, changed: 0.01),
            EventFocus.Look(time: 1.6, changed: 0.03, moving: 0.004, figure: 0.004),
            EventFocus.Look(time: 2.0, changed: 0.06, moving: 0.02, figure: 0.02),
            EventFocus.Look(time: 2.4, changed: 0.09, moving: 0.05, figure: 0.05),
            EventFocus.Look(time: 2.8, changed: 0.12, moving: 0.08, figure: 0.08),
            EventFocus.Look(time: 3.2, changed: 0.10, moving: 0.03, figure: 0.03),
        ]
        let picked = try XCTUnwrap(EventFocus.moment(looks, person: true))
        XCTAssertEqual(looks[picked.index].time, 2.8)
        XCTAssertEqual(picked.why, "person found")
        // (A second in, where a clip was always looked at before, nobody is in view yet.)
        XCTAssertEqual(looks[2].moving, 0)
    }

    func testAPostTakenForAPersonDoesntDecideTheFrame() throws {
        // A post the finder takes for a figure in every frame (it never moves), and a walker who shows at 2 s.
        let looks = [
            EventFocus.Look(time: 0.0, changed: 0, moving: 0, figure: 0.03),
            EventFocus.Look(time: 1.0, changed: 0.02, moving: 0, figure: 0.03),
            EventFocus.Look(time: 2.0, changed: 0.05, moving: 0.01, figure: 0.03),
            EventFocus.Look(time: 3.0, changed: 0.02, moving: 0, figure: 0.03),
        ]
        XCTAssertEqual(try XCTUnwrap(EventFocus.moment(looks, person: true)).index, 2)
        // Somebody who stood still the whole clip (nothing moved): where they show best.
        let still = [
            EventFocus.Look(time: 0.0, changed: 0, figure: 0.04),
            EventFocus.Look(time: 1.0, changed: 0, figure: 0.06),
            EventFocus.Look(time: 2.0, changed: 0, figure: 0.05),
        ]
        let picked = try XCTUnwrap(EventFocus.moment(still, person: true))
        XCTAssertEqual(picked.index, 1)
        XCTAssertEqual(picked.why, "person found, standing still")
    }

    func testWithNobodyFoundTheFrameWhereTheMostChanged() throws {
        // A car pulls in: biggest in the picture at 2.4 s. At 3.2 s the porch light comes on (the whole picture changes).
        let looks = [
            EventFocus.Look(time: 0.0, changed: 0),
            EventFocus.Look(time: 0.8, changed: 0.04),
            EventFocus.Look(time: 1.6, changed: 0.11),
            EventFocus.Look(time: 2.4, changed: 0.19),
            EventFocus.Look(time: 3.2, changed: 0.71),
        ]
        let car = try XCTUnwrap(EventFocus.moment(looks, person: false))
        XCTAssertEqual(looks[car.index].time, 2.4)
        XCTAssertEqual(car.why, "the most changed")
        // "Person seen" with a figure too far off to be made out: the same frame.
        let person = try XCTUnwrap(EventFocus.moment(looks, person: true))
        XCTAssertEqual(looks[person.index].time, 2.4)
        XCTAssertEqual(person.why, "no person found, the most changed")
        // A figure counts only for an alert about a person.
        let dog = [EventFocus.Look(time: 0, changed: 0.02, moving: 0.5, figure: 0.5), EventFocus.Look(time: 1, changed: 0.1)]
        XCTAssertEqual(try XCTUnwrap(EventFocus.moment(dog, person: false)).index, 1)
    }

    func testWithNothingToGoOnTheFrameASecondIn() throws {
        let looks = [0.0, 0.4, 0.8, 1.2, 1.6].map { EventFocus.Look(time: $0, changed: 0.004) }
        let picked = try XCTUnwrap(EventFocus.moment(looks, person: true))
        XCTAssertEqual(looks[picked.index].time, 0.8)   // the first of the two as near
        XCTAssertEqual(picked.why, "nothing stood out, a second in")
        // Only the light changed: the same.
        XCTAssertEqual(try XCTUnwrap(EventFocus.moment([EventFocus.Look(time: 0, changed: 0.9), EventFocus.Look(time: 1.1, changed: 0.8)], person: false)).index, 1)
        XCTAssertNil(EventFocus.moment([], person: true))
        // Of frames that show it equally, the earliest.
        let same = [EventFocus.Look(time: 0, changed: 0.1), EventFocus.Look(time: 1, changed: 0.1)]
        XCTAssertEqual(try XCTUnwrap(EventFocus.moment(same, person: false)).index, 0)
    }
}
