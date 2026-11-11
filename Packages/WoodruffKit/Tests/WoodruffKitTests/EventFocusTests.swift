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

    // MARK: Looking closer where the picture changed

    func testAFarOffFigureIsLookedForInASquareRoundWhereItChanged() throws {
        // Somebody at the end of the drive: two cells by four of a 64 by 36 grid, in a 16:9 picture.
        let patch = CGRect(x: 40.0 / 64, y: 8.0 / 36, width: 2.0 / 64, height: 4.0 / 36)
        let part = try XCTUnwrap(EventFocus.closer(patch, aspect: 16.0 / 9))
        // At least three tenths of the picture's height, and as many pixels across as down.
        XCTAssertEqual(part.height, 0.3, accuracy: 0.0001)
        XCTAssertEqual(part.width * 16 / 9, part.height, accuracy: 0.0001)
        // Round the patch, and all of it inside.
        XCTAssertEqual(part.midX, patch.midX, accuracy: 0.0001)
        XCTAssertEqual(part.midY, patch.midY, accuracy: 0.0001)
        XCTAssertLessThan(part.minX, patch.minX)
        XCTAssertGreaterThan(part.maxX, patch.maxX)
        XCTAssertLessThan(part.minY, patch.minY)
        XCTAssertGreaterThan(part.maxY, patch.maxY)
    }

    func testThePartLookedAtStaysInsideThePicture() throws {
        // In the top left corner: the square slides in rather than hanging over the edge.
        let corner = try XCTUnwrap(EventFocus.closer(CGRect(x: 0, y: 0, width: 0.03, height: 0.1), aspect: 16.0 / 9))
        XCTAssertEqual(corner.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(corner.minY, 0, accuracy: 0.0001)
        // And the bottom right.
        let far = try XCTUnwrap(EventFocus.closer(CGRect(x: 0.97, y: 0.9, width: 0.03, height: 0.1), aspect: 16.0 / 9))
        XCTAssertEqual(far.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(far.maxY, 1, accuracy: 0.0001)
        // A doorbell's upright picture (3:4): still a square of it, no wider than the picture.
        let upright = try XCTUnwrap(EventFocus.closer(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), aspect: 0.75))
        XCTAssertEqual(upright.width * 0.75, upright.height, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(upright.width, 1)
    }

    func testSomebodyCloseIsLookedForInTheWholePicture() {
        // They fill most of the picture's height: a closer look would be the picture's whole height anyway.
        XCTAssertNil(EventFocus.closer(CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.8), aspect: 16.0 / 9))
        XCTAssertNil(EventFocus.closer(CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.4), aspect: 16.0 / 9))
        // Half its height: still looked at closer.
        XCTAssertNotNil(EventFocus.closer(CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.3), aspect: 16.0 / 9))
        // Nothing to go on.
        XCTAssertNil(EventFocus.closer(CGRect(x: 0.3, y: 0.1, width: 0, height: 0.2), aspect: 16.0 / 9))
        XCTAssertNil(EventFocus.closer(CGRect(x: 0.3, y: 0.1, width: 0.1, height: 0.2), aspect: 0))
    }

    func testABoxFoundInAPartIsPlacedInTheWholePicture() {
        let part = CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.3)
        let box = EventFocus.placed(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.4), in: part)
        XCTAssertEqual(box.minX, 0.55, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 0.35, accuracy: 0.0001)
        XCTAssertEqual(box.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.12, accuracy: 0.0001)
        // The whole of the part is the part.
        XCTAssertEqual(EventFocus.placed(CGRect(x: 0, y: 0, width: 1, height: 1), in: part), part)
    }

    // MARK: The sharpest of the frames that show it

    /// A grey picture, 40 by 20: flat grey, with a figure in the box of [edge]-sharp stripes (255 and 0 side by side
    /// when [crisp]; the same stripes smeared into their neighbours when not).
    private func striped(crisp: Bool) -> [UInt8] {
        let gw = 40, gh = 20
        var g = [UInt8](repeating: 120, count: gw * gh)
        for y in 5..<15 {
            for x in 10..<20 {
                let hard: UInt8 = x % 2 == 0 ? 255 : 0
                g[y * gw + x] = crisp ? hard : (x % 2 == 0 ? 150 : 105)
            }
        }
        return g
    }

    func testACrispFigureIsSharperThanASmearedOne() {
        let box = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)
        let crisp = EventFocus.sharpness(striped(crisp: true), width: 40, height: 20, in: box)
        let smeared = EventFocus.sharpness(striped(crisp: false), width: 40, height: 20, in: box)
        XCTAssertGreaterThan(crisp, smeared * 4)
        XCTAssertGreaterThan(smeared, 0)
        // A flat wall has nothing sharp in it; a box off the picture, or a picture of the wrong size, measures 0.
        XCTAssertEqual(EventFocus.sharpness([UInt8](repeating: 90, count: 800), width: 40, height: 20, in: box), 0)
        XCTAssertEqual(EventFocus.sharpness(striped(crisp: true), width: 40, height: 20, in: CGRect(x: 2, y: 2, width: 0.1, height: 0.1)), 0)
        XCTAssertEqual(EventFocus.sharpness([1, 2, 3], width: 40, height: 20, in: box), 0)
    }

    func testOfFramesThatShowItAsWellTheSharpest() throws {
        // The same person the same size in three frames: smeared, crisp, smeared.
        XCTAssertEqual(EventFocus.clearest([(shows: 0.05, sharp: 8), (shows: 0.05, sharp: 30), (shows: 0.05, sharp: 11)]), 1)
        // Twice as large in the picture beats sharper.
        XCTAssertEqual(EventFocus.clearest([(shows: 0.10, sharp: 12), (shows: 0.05, sharp: 30)]), 0)
        // A little larger but badly smeared loses to nearly as large and crisp.
        XCTAssertEqual(EventFocus.clearest([(shows: 0.055, sharp: 6), (shows: 0.05, sharp: 30)]), 1)
        // Frames that don't show it at all never win; none at all is nil; no sharpness known is just the largest.
        XCTAssertEqual(EventFocus.clearest([(shows: 0, sharp: 99), (shows: 0.01, sharp: 1)]), 1)
        XCTAssertNil(EventFocus.clearest([]))
        XCTAssertNil(EventFocus.clearest([(shows: 0, sharp: 5)]))
        XCTAssertEqual(EventFocus.clearest([(shows: 0.02, sharp: 0), (shows: 0.03, sharp: 0)]), 1)
        // Equal in every way: the earliest.
        XCTAssertEqual(EventFocus.clearest([(shows: 0.02, sharp: 5), (shows: 0.02, sharp: 5)]), 0)
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
