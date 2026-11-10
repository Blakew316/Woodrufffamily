import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import WoodruffKit

/// Vehicle Alerts' rules for what's news, on boxes as the family's Front Driveway camera gave them: a wide view down
/// an empty driveway to the street, with the neighbours' cars always parked across it.
final class VehicleTrackerTests: XCTestCase {
    /// The driveway, its apron and the near lane right in front of it, as outlined on that camera's picture.
    private static let driveway = "0.28,0.20 0.80,0.22 0.86,0.34 0.72,0.41 0.71,1.00 0.08,1.00 0.02,0.62 0.10,0.60 0.32,0.30"

    private static func car(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ sure: Double = 0.96, _ label: String = "car") -> VehicleSighting {
        VehicleSighting(label: label, confidence: sure, box: CGRect(x: x, y: y, width: w, height: h))
    }
    /// The neighbours' cars across the street, as found in nearly every daytime picture.
    private static let parked = [car(0.23, 0.09, 0.07, 0.06, 0.95), car(0.29, 0.06, 0.06, 0.05, 0.8, "truck"), car(0.18, 0.08, 0.05, 0.06, 0.85)]
    private static let onDrive = car(0.30, 0.45, 0.30, 0.30)

    /// A camera's picture on its small grid, and what follows it.
    private struct Camera {
        var motion = VehicleMotion()
        var tracker = VehicleTracker()
        var grid = [Float](repeating: 100, count: 64 * 36)
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var zone = VehicleZone(VehicleTrackerTests.driveway)

        init() { _ = look([]) }

        /// One look, [seconds] after the last: the picture changes under each of [changing] (or all of it, the
        /// [light]), and the detector finds [found].
        mutating func look(_ found: [VehicleSighting], changing: [CGRect] = [], light: Bool = false,
                           after seconds: TimeInterval = 1) -> [VehicleTracker.Outcome] {
            now += seconds
            if light { for i in grid.indices { grid[i] = grid[i] < 150 ? 200 : 100 } }
            for box in changing {
                for y in 0..<36 { for x in 0..<64 where box.contains(CGPoint(x: (Double(x) + 0.5) / 64, y: (Double(y) + 0.5) / 36)) {
                    grid[y * 64 + x] = grid[y * 64 + x] < 150 ? 200 : 100
                } }
            }
            motion.look(at: grid, width: 64, height: 36, now: now)
            return tracker.look(at: found, motion: motion, zone: zone, now: now)
        }
    }

    func testTheDrivewaysOutline() throws {
        let zone = try XCTUnwrap(VehicleZone(Self.driveway))
        XCTAssertEqual(zone.points.count, 9)
        XCTAssertTrue(zone.holds(Self.onDrive.box), "a car on the driveway")
        XCTAssertTrue(zone.holds(CGRect(x: 0.45, y: 0.12, width: 0.25, height: 0.16)), "a car stopped at its mouth")
        XCTAssertFalse(zone.holds(CGRect(x: 0.83, y: 0.23, width: 0.16, height: 0.21)), "the SUV at the kerb next door")
        XCTAssertFalse(zone.holds(CGRect(x: 0.51, y: 0.08, width: 0.20, height: 0.12)), "a car passing in the street")
        XCTAssertFalse(zone.holds(CGRect(x: 0.37, y: 0.06, width: 0.17, height: 0.11)), "another passing")
        for p in Self.parked { XCTAssertFalse(zone.holds(p.box), "parked across the street") }
        XCTAssertNil(VehicleZone("0.1,0.2 0.3,0.4"), "two points aren't an outline")
        XCTAssertNil(VehicleZone("0.1,0.2 nonsense 0.3,0.4"))
        XCTAssertNil(VehicleZone(""))
    }

    func testThePicturesChanges() {
        var m = VehicleMotion()
        var grid = [Float](repeating: 100, count: 64 * 36)
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        m.look(at: grid, width: 64, height: 36, now: t)
        // The camera's exposure drifting (all of it a little brighter) is no change.
        for i in grid.indices { grid[i] += 10 }
        m.look(at: grid, width: 64, height: 36, now: t + 1)
        XCTAssertEqual(m.share, 0)
        XCTAssertFalse(m.lightChanged)
        // A car's worth of it changing is, there and nowhere else, and for a few seconds after.
        let box = CGRect(x: 0.30, y: 0.45, width: 0.30, height: 0.30)
        for y in 17..<27 { for x in 20..<38 { grid[y * 64 + x] = 200 } }
        m.look(at: grid, width: 64, height: 36, now: t + 2)
        XCTAssertFalse(m.lightChanged)
        XCTAssertGreaterThan(m.share(in: box, within: 8, of: t + 2), 0.7)
        XCTAssertEqual(m.share(in: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2), within: 8, of: t + 2), 0)
        m.look(at: grid, width: 64, height: 36, now: t + 3)
        XCTAssertGreaterThan(m.share(in: box, within: 8, of: t + 3), 0.7, "still lately")
        XCTAssertEqual(m.share(in: box, within: 8, of: t + 30), 0, "no longer")
        // Night vision coming on (everything at once) is the light, and marks nothing as changed.
        for i in grid.indices { grid[i] = grid[i] < 150 ? 220 : 40 }
        m.look(at: grid, width: 64, height: 36, now: t + 40)
        XCTAssertTrue(m.lightChanged)
        XCTAssertEqual(m.share(in: box, within: 8, of: t + 40), 0)
        // All of it darker at once is too.
        for i in grid.indices { grid[i] -= 30 }
        m.look(at: grid, width: 64, height: 36, now: t + 41)
        XCTAssertTrue(m.lightChanged)
    }

    func testAVehicleFoundTwiceIsOne() {
        // The whole picture finds the car; two parts of the picture each find a piece of it, one a little surer.
        let found = [Self.car(0.30, 0.45, 0.30, 0.30, 0.93), Self.car(0.30, 0.45, 0.18, 0.30, 0.97), Self.car(0.44, 0.47, 0.16, 0.27, 0.6)]
            + Self.parked
        let merged = VehicleSighting.merged(found)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.first?.confidence, 0.97)
        XCTAssertEqual(merged.first?.box, CGRect(x: 0.30, y: 0.45, width: 0.30, height: 0.30), "the whole car's box")
    }

    func testTheNeighboursParkedCarsAreNeverNews() {
        var cam = Camera()
        for i in 0..<400 {
            // Found most of the time, their boxes a hair different each look; the light changing at dusk; shadows moving.
            let wobble = Double(i % 3) * 0.004
            var found = [Self.car(0.23 + wobble, 0.09, 0.07, 0.06, 0.9), Self.car(0.29, 0.06 + wobble, 0.06, 0.05, 0.7, "truck")]
            if i % 2 == 0 { found.append(Self.parked[2]) }
            let out = cam.look(found, changing: i % 7 == 0 ? [CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.2)] : [], light: i == 200)
            XCTAssertEqual(out, [], "look \(i)")
        }
    }

    func testACarComingOntoTheDrivewayIsNewsOnce() {
        var cam = Camera()
        for _ in 0..<30 { XCTAssertEqual(cam.look(Self.parked), []) }
        // It turns up (the picture changes where it is): not news at its first look, news at its second, never again.
        XCTAssertEqual(cam.look(Self.parked + [Self.onDrive], changing: [Self.onDrive.box]), [])
        XCTAssertEqual(cam.look(Self.parked + [Self.onDrive]), [.arrived(Self.onDrive)])
        for i in 0..<600 {
            // It stays for ten minutes, lost by the detector now and then for up to a minute.
            let lost = (100..<160).contains(i)
            XCTAssertEqual(cam.look(Self.parked + (lost ? [] : [Self.onDrive])), [], "look \(i)")
        }
    }

    func testFoundAtTwoLooksOfThree() {
        var cam = Camera()
        XCTAssertEqual(cam.look([Self.onDrive], changing: [Self.onDrive.box]), [])
        XCTAssertEqual(cam.look([]), [])
        XCTAssertEqual(cam.look([Self.onDrive]), [.arrived(Self.onDrive)])
    }

    func testACarDrivingPastIsNotNews() {
        var cam = Camera()
        // Along the street, a fifth of the picture further at each look (never where it was a second ago).
        for i in 0..<5 {
            let at = Self.car(0.05 + Double(i) * 0.2, 0.08, 0.20, 0.12)
            XCTAssertEqual(cam.look(Self.parked + [at], changing: [at.box]), [], "look \(i)")
        }
        // One slowing in the near lane right at the driveway's mouth for a single look, then gone.
        let mouth = Self.car(0.45, 0.12, 0.25, 0.16)
        XCTAssertEqual(cam.look(Self.parked + [mouth], changing: [mouth.box]), [])
        for _ in 0..<5 { XCTAssertEqual(cam.look(Self.parked), []) }
        // The SUV stopping at the kerb next door, for ten minutes.
        let kerb = Self.car(0.83, 0.23, 0.16, 0.21)
        XCTAssertEqual(cam.look(Self.parked + [kerb], changing: [kerb.box]), [])
        for _ in 0..<600 { XCTAssertEqual(cam.look(Self.parked + [kerb]), []) }
    }

    func testACarStoppingAtTheMouthIsNews() {
        var cam = Camera()
        let mouth = Self.car(0.45, 0.12, 0.25, 0.16)
        XCTAssertEqual(cam.look(Self.parked + [mouth], changing: [mouth.box]), [])
        XCTAssertEqual(cam.look(Self.parked + [mouth]), [.arrived(mouth)])
    }

    func testAParkedCarOnlyNowMadeOutIsPassedOver() {
        var cam = Camera()
        for _ in 0..<60 { XCTAssertEqual(cam.look([]), []) }
        // It was on the drive all along; the detector finds it only now. Nothing moved: said once, not news.
        XCTAssertEqual(cam.look([Self.onDrive]), [])
        XCTAssertEqual(cam.look([Self.onDrive]), [.passedOver(Self.onDrive, why: "nothing moved there")])
        // Lost for five minutes (the night), found again: still not news, and not said again.
        for _ in 0..<300 { XCTAssertEqual(cam.look([]), []) }
        for _ in 0..<10 { XCTAssertEqual(cam.look([Self.onDrive]), []) }
        // Lost for an hour (longer than its place is remembered), found again with nothing having moved.
        for _ in 0..<120 { XCTAssertEqual(cam.look([], after: 30), []) }
        XCTAssertEqual(cam.look([Self.onDrive]), [])
        XCTAssertEqual(cam.look([Self.onDrive]), [.passedOver(Self.onDrive, why: "nothing moved there")])
    }

    func testWhatTurnsUpAsTheLightChangesIsScenery() {
        var cam = Camera()
        for _ in 0..<10 { XCTAssertEqual(cam.look([]), []) }
        // Morning: night vision goes off and the car that stood on the drive all night is made out.
        XCTAssertEqual(cam.look([Self.onDrive], light: true), [])
        for _ in 0..<60 { XCTAssertEqual(cam.look([Self.onDrive]), []) }
    }

    func testAnotherCarSoonAfterAndLater() {
        var cam = Camera()
        let first = Self.onDrive, second = Self.car(0.15, 0.62, 0.25, 0.3)
        XCTAssertEqual(cam.look([first], changing: [first.box]), [])
        XCTAssertEqual(cam.look([first]), [.arrived(first)])
        // A second one twenty seconds later, the drive busy all the while (the first still pulling up): the same visit.
        for i in 0..<20 {
            let creeping = Self.car(0.30, 0.45 + Double(i) * 0.02, 0.30, 0.30)
            _ = cam.look([creeping], changing: [creeping.box])
        }
        XCTAssertEqual(cam.look([second], changing: [second.box]), [])
        XCTAssertEqual(cam.look([second]), [.passedOver(second, why: "too soon after the last one")])
        // Both leave. Two minutes of nothing, then another: news again, though three minutes haven't passed.
        for _ in 0..<120 { XCTAssertEqual(cam.look([]), []) }
        XCTAssertEqual(cam.look([first], changing: [first.box]), [])
        XCTAssertEqual(cam.look([first]), [.arrived(first)])
    }

    func testACarWhereAnotherStoodIsNewsWhenItDroveIn() {
        var cam = Camera()
        XCTAssertEqual(cam.look([Self.onDrive], changing: [Self.onDrive.box]), [])
        XCTAssertEqual(cam.look([Self.onDrive]), [.arrived(Self.onDrive)])
        // It leaves; ten minutes later another pulls into the same spot (the picture changes there).
        for _ in 0..<600 { XCTAssertEqual(cam.look([]), []) }
        XCTAssertEqual(cam.look([Self.onDrive], changing: [Self.onDrive.box]), [])
        XCTAssertEqual(cam.look([Self.onDrive]), [.arrived(Self.onDrive)])
    }

    func testAnUnsureFindingIsNothing() {
        var cam = Camera()
        let faint = Self.car(0.30, 0.45, 0.30, 0.30, 0.3)
        XCTAssertEqual(cam.look([faint], changing: [faint.box]), [])
        XCTAssertEqual(cam.look([faint]), [])
        XCTAssertEqual(cam.tracker.following, 0)
    }

    func testAnywhereCountsWithoutAnOutline() {
        var cam = Camera()
        cam.zone = nil
        let kerb = Self.car(0.83, 0.23, 0.16, 0.21)
        XCTAssertEqual(cam.look([kerb], changing: [kerb.box]), [])
        XCTAssertEqual(cam.look([kerb]), [.arrived(kerb)])
    }
}
