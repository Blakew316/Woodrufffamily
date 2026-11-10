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
}
