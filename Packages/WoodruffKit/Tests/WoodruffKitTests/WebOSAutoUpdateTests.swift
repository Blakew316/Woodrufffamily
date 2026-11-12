import XCTest
@testable import WoodruffKit

final class WebOSAutoUpdateTests: XCTestCase {
    func testABuildIsTriedAtOnceThenHourlyThenTwiceADayForEver() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(WebOSAutoUpdate.due(nil, tag: "webos-33", now: now))
        let once = WebOSAutoUpdate.Tried(tag: "webos-33", tries: 1, at: now)
        XCTAssertFalse(WebOSAutoUpdate.due(once, tag: "webos-33", now: now.addingTimeInterval(600)))
        XCTAssertTrue(WebOSAutoUpdate.due(once, tag: "webos-33", now: now.addingTimeInterval(3600)))
        // A newer build starts afresh.
        XCTAssertTrue(WebOSAutoUpdate.due(once, tag: "webos-34", now: now.addingTimeInterval(60)))
        let spent = WebOSAutoUpdate.Tried(tag: "webos-33", tries: 4, at: now)
        XCTAssertFalse(WebOSAutoUpdate.due(spent, tag: "webos-33", now: now.addingTimeInterval(3600)))
        XCTAssertTrue(WebOSAutoUpdate.due(spent, tag: "webos-33", now: now.addingTimeInterval(12 * 3600)))
        // One the TV said it installed isn't put on again, whatever version the TV goes on reporting.
        let done = WebOSAutoUpdate.Tried(tag: "webos-33", tries: 1, at: now, done: true)
        XCTAssertFalse(WebOSAutoUpdate.due(done, tag: "webos-33", now: now.addingTimeInterval(7 * 86_400)))
        XCTAssertTrue(WebOSAutoUpdate.due(done, tag: "webos-34", now: now))
    }

    func testTheSavedWayInComesFirstThenEachAddressBothWays() {
        let saved = WebOSSSH(host: "10.0.0.9", mode: .developerMode, keyPath: "~/.ssh/k")
        let ways = WebOSAutoUpdate.ways(saved: saved, hosts: ["10.0.0.9", nil, " ", "10.0.0.12", "10.0.0.12"])
        XCTAssertEqual(ways.map { "\($0.user)@\($0.host):\($0.port)" },
                       ["prisoner@10.0.0.9:9922", "root@10.0.0.9:22", "root@10.0.0.12:22", "prisoner@10.0.0.12:9922"])
        XCTAssertEqual(ways[1].keyPath, "~/.ssh/k")
        XCTAssertTrue(WebOSAutoUpdate.ways(saved: nil, hosts: [nil, ""]).isEmpty)
    }
}
