import XCTest
@testable import WoodruffKit

/// What keeps the TVs' state live: what's playing laid over the last answer without jumping back, and the
/// rules that merge every hub's answer into one list, whatever order the answers arrive in.
final class RealtimeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func show(_ title: String = "Midnight Harbor", playing: Bool = true, at position: Double, key: String? = "drive:m1") -> NowPlaying {
        NowPlaying(title: title, playing: playing, position: position, duration: 6_000_000, key: key)
    }

    // MARK: Position

    func testPositionRunsOnWhilePlayingAndStopsAtTheEnd() {
        var p = show(at: 60_000)
        p.reportedAt = t0
        XCTAssertEqual(p.estimatedPosition(at: t0.addingTimeInterval(5)), 65_000, accuracy: 0.001)
        XCTAssertEqual(p.estimatedPosition(at: t0.addingTimeInterval(10_000)), 6_000_000, accuracy: 0.001)
        // A clock that went backwards never moves it back.
        XCTAssertEqual(p.estimatedPosition(at: t0.addingTimeInterval(-30)), 60_000, accuracy: 0.001)
        var paused = show(playing: false, at: 60_000)
        paused.reportedAt = t0
        XCTAssertEqual(paused.estimatedPosition(at: t0.addingTimeInterval(30)), 60_000, accuracy: 0.001)
        // No arrival time: just what the TV said.
        XCTAssertEqual(show(at: 1_000).estimatedPosition(at: t0), 1_000, accuracy: 0.001)
    }

    func testArrivalTimeIsNotPartOfTheTVsJSON() throws {
        var p = show(at: 1_000)
        p.reportedAt = t0
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertFalse(json.contains("reportedAt"))
        let back = try JSONDecoder().decode(NowPlaying.self, from: Data(#"{"title":"A","playing":true,"position":5,"duration":10}"#.utf8))
        XCTAssertNil(back.reportedAt)
        XCTAssertEqual(back.position, 5)
    }

    // MARK: Smoothing

    func testFirstAnswerIsAnchoredWhenItArrives() {
        let p = show(at: 10_000).smoothed(after: nil, now: t0)
        XCTAssertEqual(p.reportedAt, t0)
        XCTAssertEqual(p.position, 10_000)
    }

    func testSameAnswerChangesNothing() {
        let first = show(playing: false, at: 10_000).smoothed(after: nil, now: t0)
        let again = show(playing: false, at: 10_000).smoothed(after: first, now: t0.addingTimeInterval(2))
        XCTAssertEqual(again, first)
    }

    func testSlightlyStaleAnswerNeverPullsTheBarBack() {
        let first = show(at: 10_000).smoothed(after: nil, now: t0)
        // 3 s later the bar shows 13 s; a relayed answer still says 11 s.
        let later = show(at: 11_000).smoothed(after: first, now: t0.addingTimeInterval(3))
        XCTAssertEqual(later, first, "kept on its own clock, so nothing redraws")
        XCTAssertGreaterThanOrEqual(later.estimatedPosition(at: t0.addingTimeInterval(3)), 13_000 - 0.001)
    }

    func testAnswerInStepKeepsTheSameAnchor() {
        let first = show(at: 10_000).smoothed(after: nil, now: t0)
        let later = show(at: 12_400).smoothed(after: first, now: t0.addingTimeInterval(2))
        XCTAssertEqual(later, first)
    }

    func testSkipsShowAtOnce() {
        let first = show(at: 100_000).smoothed(after: nil, now: t0)
        let now = t0.addingTimeInterval(2)
        let back = show(at: 92_000).smoothed(after: first, now: now)     // ↺10
        XCTAssertEqual(back.position, 92_000)
        XCTAssertEqual(back.reportedAt, now)
        let ahead = show(at: 132_000).smoothed(after: first, now: now)   // 30↻
        XCTAssertEqual(ahead.position, 132_000)
        XCTAssertEqual(ahead.reportedAt, now)
    }

    func testPauseAndNewTitleShowAtOnce() {
        let first = show(at: 100_000).smoothed(after: nil, now: t0)
        let now = t0.addingTimeInterval(1)
        let paused = show(playing: false, at: 101_000).smoothed(after: first, now: now)
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.position, 101_000)
        XCTAssertEqual(paused.reportedAt, now)
        let other = show("Ironwood", at: 5_000, key: "drive:m2").smoothed(after: first, now: now)
        XCTAssertEqual(other.title, "Ironwood")
        XCTAssertEqual(other.position, 5_000)
        XCTAssertEqual(other.reportedAt, now)
    }

    func testReanchoringNeverMovesBackwards() {
        let first = show(at: 0).smoothed(after: nil, now: t0)
        let now = t0.addingTimeInterval(20)                    // the bar shows 20 s
        let stale = show(at: 17_000).smoothed(after: first, now: now)
        XCTAssertEqual(stale.reportedAt, now)
        XCTAssertEqual(stale.position ?? 0, 20_000, accuracy: 0.001)
        let ahead = show(at: 21_000).smoothed(after: first, now: now)
        XCTAssertEqual(ahead.position ?? 0, 21_000, accuracy: 0.001)
    }

    func testOtherChangesComeThroughWhileTheClockIsKept() {
        let first = show(at: 10_000).smoothed(after: nil, now: t0)
        var next = show(at: 11_000)
        next.can = ["playpause", "fwd30"]
        let later = next.smoothed(after: first, now: t0.addingTimeInterval(2))
        XCTAssertEqual(later.can, ["playpause", "fwd30"])
        XCTAssertEqual(later.position, 10_000)
        XCTAssertEqual(later.reportedAt, t0)
    }

    // MARK: Merging hubs' answers

    private static func base(_ s: String) -> URL { URL(string: s) ?? URL(fileURLWithPath: "/") }
    private let hubA = Hub(id: "tv-a", name: "Living Room", connection: TVConnection(base: RealtimeTests.base("http://192.168.1.10:8090"), key: "a"))
    private let hubB = Hub(id: "tv-b", name: "Den", connection: TVConnection(base: RealtimeTests.base("http://192.168.1.11:8090"), key: "b"))

    private func entry(_ id: String, _ name: String, online: Bool = true, playing: NowPlaying? = nil, link: String? = "ok") -> TVListEntry {
        TVListEntry(id: id, name: name, online: online, onScreen: online, playing: playing, version: "2.0.1", seen: nil, link: link, health: nil)
    }

    private func merge(_ hubs: [Hub], _ answers: [String: HubAnswer], before: [FleetTV] = [], now: Date? = nil) -> [String: FleetTV] {
        let list = FleetMerge.merge(hubs: hubs, answers: answers,
                                    before: Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                    platforms: [:], now: now ?? t0)
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testOwnAnswerBeatsRelayedWhateverTheOrder() {
        let own = HubAnswer.answered([entry("this", "Living Room", playing: show(at: 1_000))])
        let relayed = HubAnswer.answered([entry("this", "Den"), entry("tv-a", "Living Room", online: false)])
        for hubs in [[hubA, hubB], [hubB, hubA]] {
            let tvs = merge(hubs, ["tv-a": own, "tv-b": relayed])
            XCTAssertEqual(tvs["tv-a"]?.isHub, true)
            XCTAssertEqual(tvs["tv-a"]?.online, true)
            XCTAssertEqual(tvs["tv-a"]?.playing?.title, "Midnight Harbor")
            XCTAssertEqual(tvs.count, 2)
        }
    }

    func testRelayedOnBeatsRelayedOff() {
        let kitchenOn = HubAnswer.answered([entry("this", "Living Room"), entry("tv-k", "Kitchen", online: true)])
        let kitchenOff = HubAnswer.answered([entry("this", "Den"), entry("tv-k", "Kitchen", online: false)])
        for hubs in [[hubA, hubB], [hubB, hubA]] {
            let tvs = merge(hubs, ["tv-a": kitchenOn, "tv-b": kitchenOff])
            XCTAssertEqual(tvs["tv-k"]?.online, true)
            XCTAssertEqual(tvs["tv-k"]?.hubID, "tv-a")
            XCTAssertEqual(tvs["tv-k"]?.routeID, "tv-k")
        }
    }

    func testHubThatDoesntAnswerKeepsWhatWasKnownOffline() {
        let before = merge([hubA], ["tv-a": .answered([entry("this", "Living Room", playing: show(at: 1_000)),
                                                       entry("tv-k", "Kitchen", playing: show(at: 2_000))])])
        let tvs = merge([hubA], ["tv-a": .unreachable], before: Array(before.values))
        XCTAssertEqual(tvs["tv-a"]?.online, false)
        XCTAssertNil(tvs["tv-a"]?.playing)
        XCTAssertEqual(tvs["tv-a"]?.version, "2.0.1", "keeps what was known of it")
        XCTAssertEqual(tvs["tv-k"]?.online, false)
        XCTAssertNil(tvs["tv-k"]?.playing)
    }

    func testAnotherHubsReportBeatsAnOfflinePlaceholderWhateverTheOrder() {
        let before = merge([hubA, hubB], ["tv-a": .answered([entry("this", "Living Room")]),
                                          "tv-b": .answered([entry("this", "Den")])])
        // Living Room doesn't answer this phone, but Den still reaches it.
        let viaDen = HubAnswer.answered([entry("this", "Den"), entry("tv-a", "Living Room", online: true, playing: show(at: 5_000))])
        for hubs in [[hubA, hubB], [hubB, hubA]] {
            let tvs = merge(hubs, ["tv-a": .unreachable, "tv-b": viaDen], before: Array(before.values))
            XCTAssertEqual(tvs["tv-a"]?.online, true)
            XCTAssertEqual(tvs["tv-a"]?.hubID, "tv-b")
            XCTAssertEqual(tvs["tv-a"]?.playing?.position, 5_000)
        }
    }

    func testHubNotHeardFromYetKeepsWhatWasShown() {
        let before = merge([hubA, hubB], ["tv-a": .answered([entry("this", "Living Room")]),
                                          "tv-b": .answered([entry("this", "Den"), entry("tv-k", "Kitchen", playing: show(at: 3_000))])])
        // Living Room answers first after a restart; Den hasn't yet.
        let tvs = merge([hubA, hubB], ["tv-a": .answered([entry("this", "Living Room", playing: show(at: 9_000))])], before: Array(before.values))
        XCTAssertEqual(tvs["tv-a"]?.playing?.position, 9_000)
        XCTAssertEqual(tvs["tv-b"]?.online, true)
        XCTAssertEqual(tvs["tv-k"]?.online, true)
        XCTAssertEqual(tvs["tv-k"]?.playing?.position, 3_000)
    }

    func testTVsAHubNoLongerListsGo() {
        let before = merge([hubA], ["tv-a": .answered([entry("this", "Living Room"), entry("tv-k", "Kitchen")])])
        let tvs = merge([hubA], ["tv-a": .answered([entry("this", "Living Room")])], before: Array(before.values))
        XCTAssertNil(tvs["tv-k"])
        XCTAssertEqual(tvs.count, 1)
    }

    func testUnpairedHubsTVsGo() {
        let before = merge([hubA, hubB], ["tv-a": .answered([entry("this", "Living Room")]),
                                          "tv-b": .answered([entry("this", "Den"), entry("tv-k", "Kitchen")])])
        let tvs = merge([hubA], ["tv-a": .answered([entry("this", "Living Room")])], before: Array(before.values))
        XCTAssertEqual(Set(tvs.keys), ["tv-a"])
    }

    func testMergeKeepsTheProgressClock() {
        let first = merge([hubA], ["tv-a": .answered([entry("this", "Living Room", playing: show(at: 10_000))])])
        XCTAssertEqual(first["tv-a"]?.playing?.reportedAt, t0)
        let later = merge([hubA], ["tv-a": .answered([entry("this", "Living Room", playing: show(at: 11_000))])],
                          before: Array(first.values), now: t0.addingTimeInterval(3))
        XCTAssertEqual(later["tv-a"], first["tv-a"], "a slightly stale answer changes nothing")
    }

    func testOrderPutsPairedTVsFirstAndNeverSwapsTwins() {
        let a = FleetTV(id: "b-2", name: "Kitchen", online: true, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: "h", routeID: "b-2", platform: nil)
        let b = FleetTV(id: "b-1", name: "Kitchen", online: true, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: "h", routeID: "b-1", platform: nil)
        let hub = FleetTV(id: "h", name: "Zebra", online: true, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: "h", routeID: "this", platform: nil)
        XCTAssertEqual([a, b, hub].sorted(by: FleetMerge.order).map(\.id), ["h", "b-1", "b-2"])
        XCTAssertEqual([b, hub, a].sorted(by: FleetMerge.order).map(\.id), ["h", "b-1", "b-2"])
    }

    func testHubAnswer() {
        XCTAssertTrue(HubAnswer.answered([]).isAnswered)
        XCTAssertFalse(HubAnswer.unreachable.isAnswered)
    }

    // MARK: Addresses

    func testHomeAddresses() {
        XCTAssertTrue(Fleet.isHomeAddress("192.168.68.91"))
        XCTAssertTrue(Fleet.isHomeAddress("10.0.0.5"))
        XCTAssertTrue(Fleet.isHomeAddress("172.20.1.2"))
        XCTAssertTrue(Fleet.isHomeAddress("living-room.local"))
        XCTAssertFalse(Fleet.isHomeAddress("172.32.1.2"))
        XCTAssertFalse(Fleet.isHomeAddress("8.8.8.8"))
        XCTAssertFalse(Fleet.isHomeAddress("tv.example.com"))
        XCTAssertFalse(Fleet.isHomeAddress("192.168.1"))
        XCTAssertFalse(Fleet.isHomeAddress(nil))
    }
}
