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

    // MARK: Only what's on, and playing now

    private func mergeStale(_ hubs: [Hub], _ answers: [String: HubAnswer], now: Date, answeredAt: [String: Date] = [:],
                            staleAfter: TimeInterval = .infinity, staleRelays: Set<String> = []) -> [String: FleetTV] {
        let list = FleetMerge.merge(hubs: hubs, answers: answers, before: [:], platforms: [:], now: now,
                                    answeredAt: answeredAt, staleAfter: staleAfter, staleRelays: staleRelays)
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testATVPassedOnAsOffPlaysNothingAndShowsNothing() {
        // The hub still has what the Kitchen last played, and its screen, but says it's off.
        let off = TVListEntry(id: "tv-k", name: "Kitchen", online: false, onScreen: true, playing: show(at: 2_000),
                              version: "2.0.1", seen: nil, link: "ok", health: nil)
        let tvs = merge([hubA], ["tv-a": .answered([entry("this", "Living Room"), off])])
        XCTAssertEqual(tvs["tv-k"]?.online, false)
        XCTAssertNil(tvs["tv-k"]?.playing)
        XCTAssertEqual(tvs["tv-k"]?.onScreen, false)
        XCTAssertNil(tvs["tv-k"]?.nowPlaying)
    }

    func testAStaleAnswerSaysNothingAboutWhatsPlaying() {
        let answer = HubAnswer.answered([entry("this", "Living Room", playing: show(at: 1_000)),
                                         entry("tv-k", "Kitchen", playing: show("Ironwood", at: 2_000, key: "drive:m2"))])
        let fresh = mergeStale([hubA], ["tv-a": answer], now: t0.addingTimeInterval(20), answeredAt: ["tv-a": t0], staleAfter: 20)
        XCTAssertEqual(fresh["tv-a"]?.playing?.title, "Midnight Harbor", "20 seconds old is still fresh")
        XCTAssertEqual(fresh["tv-k"]?.playing?.title, "Ironwood")
        let stale = mergeStale([hubA], ["tv-a": answer], now: t0.addingTimeInterval(21), answeredAt: ["tv-a": t0], staleAfter: 20)
        XCTAssertNil(stale["tv-a"]?.playing)
        XCTAssertNil(stale["tv-k"]?.playing)
        // The TVs themselves stay as they were.
        XCTAssertEqual(stale["tv-a"]?.online, true)
        XCTAssertEqual(stale["tv-a"]?.version, "2.0.1")
        XCTAssertEqual(stale["tv-a"]?.onScreen, true)
        XCTAssertEqual(stale["tv-k"]?.online, true)
        XCTAssertEqual(stale["tv-k"]?.version, "2.0.1")
        // A hub with no time given is taken as fresh.
        XCTAssertEqual(mergeStale([hubA], ["tv-a": answer], now: t0.addingTimeInterval(500), staleAfter: 20)["tv-a"]?.playing?.title, "Midnight Harbor")
    }

    func testAStaleRelayDropsOnlyWhatThatTVPlays() {
        let answer = HubAnswer.answered([entry("this", "Living Room", playing: show(at: 1_000)),
                                         entry("tv-k", "Kitchen", playing: show("Ironwood", at: 2_000, key: "drive:m2")),
                                         entry("tv-d", "Den", playing: show("Orbit", at: 3_000, key: "drive:m3"))])
        let tvs = mergeStale([hubA], ["tv-a": answer], now: t0,
                             staleRelays: [FleetMerge.relayKey("tv-a", "tv-k"), FleetMerge.relayKey("tv-a", "this")])
        XCTAssertNil(tvs["tv-k"]?.playing)
        XCTAssertEqual(tvs["tv-k"]?.online, true, "the TV itself stays as it was")
        XCTAssertEqual(tvs["tv-k"]?.version, "2.0.1")
        XCTAssertEqual(tvs["tv-a"]?.playing?.title, "Midnight Harbor", "a hub's word about itself is never a relay")
        XCTAssertEqual(tvs["tv-d"]?.playing?.title, "Orbit")
        // The same TV passed on by another hub is that hub's own (stale) relay or not.
        XCTAssertEqual(mergeStale([hubA], ["tv-a": answer], now: t0, staleRelays: [FleetMerge.relayKey("tv-b", "tv-k")])["tv-k"]?.playing?.title, "Ironwood")
    }

    func testARelayGoesStaleOnlyWhenItsHubHasntHeardFromItFor20Seconds() {
        var r = FleetMerge.relay(seen: 1_000, at: t0, kept: nil)
        XCTAssertFalse(r.stale)
        r = FleetMerge.relay(seen: 1_000, at: t0.addingTimeInterval(19), kept: r.kept)
        XCTAssertFalse(r.stale)
        r = FleetMerge.relay(seen: 1_000, at: t0.addingTimeInterval(20), kept: r.kept)
        XCTAssertTrue(r.stale)
        // Heard from again: fresh at once, counted from that answer.
        r = FleetMerge.relay(seen: 2_000, at: t0.addingTimeInterval(25), kept: r.kept)
        XCTAssertFalse(r.stale)
        XCTAssertEqual(r.kept.since, t0.addingTimeInterval(25))
        r = FleetMerge.relay(seen: 2_000, at: t0.addingTimeInterval(44), kept: r.kept)
        XCTAssertFalse(r.stale)
    }

    func testARelayAskedLessOftenGetsLonger() {
        // In the background an iPhone asks every 25 s (stale after 75): a hub passing on the same `seen` once or twice
        // more (its check of the TV ran late) hasn't lost it.
        var r = FleetMerge.relay(seen: 1_000, at: t0, kept: nil, after: 75)
        r = FleetMerge.relay(seen: 1_000, at: t0.addingTimeInterval(25), kept: r.kept, after: 75)
        XCTAssertFalse(r.stale)
        r = FleetMerge.relay(seen: 1_000, at: t0.addingTimeInterval(50), kept: r.kept, after: 75)
        XCTAssertFalse(r.stale)
        r = FleetMerge.relay(seen: 1_000, at: t0.addingTimeInterval(75), kept: r.kept, after: 75)
        XCTAssertTrue(r.stale)
    }

    func testAFreshRelayBeatsAStaleOneWhateverTheOrder() {
        let a = HubAnswer.answered([entry("this", "Living Room"), entry("tv-k", "Kitchen", playing: show("Ironwood", at: 2_000, key: "drive:m2"))])
        let b = HubAnswer.answered([entry("this", "Den"), entry("tv-k", "Kitchen", playing: show("Ironwood", at: 2_000, key: "drive:m2"))])
        for hubs in [[hubA, hubB], [hubB, hubA]] {
            // Living Room hasn't heard from the Kitchen lately; the Den has.
            let relay = mergeStale(hubs, ["tv-a": a, "tv-b": b], now: t0, staleRelays: [FleetMerge.relayKey("tv-a", "tv-k")])
            XCTAssertEqual(relay["tv-k"]?.hubID, "tv-b")
            XCTAssertEqual(relay["tv-k"]?.playing?.title, "Ironwood")
            // Living Room's whole answer is old; the Den's is fresh.
            let old = mergeStale(hubs, ["tv-a": a, "tv-b": b], now: t0.addingTimeInterval(30),
                                 answeredAt: ["tv-a": t0, "tv-b": t0.addingTimeInterval(29)], staleAfter: 20)
            XCTAssertEqual(old["tv-k"]?.hubID, "tv-b")
            XCTAssertEqual(old["tv-k"]?.playing?.title, "Ironwood")
            // A TV's own word still comes first, old or not.
            XCTAssertEqual(old["tv-a"]?.isHub, true)
        }
        // Both believed: the hub paired first, as before.
        XCTAssertEqual(mergeStale([hubA, hubB], ["tv-a": a, "tv-b": b], now: t0)["tv-k"]?.hubID, "tv-a")
        XCTAssertEqual(mergeStale([hubB, hubA], ["tv-a": a, "tv-b": b], now: t0)["tv-k"]?.hubID, "tv-b")
    }

    func testATitleFirstSeenPausedCountsAsPausedLongAtOnce() {
        // Just launched, or an Android session left behind after leaving YouTube: there's no telling when it paused.
        let first = FleetMerge.pause(show(playing: false, at: 50_000), mark: nil, heardAt: t0, now: t0)
        XCTAssertTrue(first.long)
        let still = FleetMerge.pause(show(playing: false, at: 50_000), mark: first.mark, heardAt: t0.addingTimeInterval(2), now: t0.addingTimeInterval(2))
        XCTAssertTrue(still.long)
        // Played again: it counts at once.
        let played = FleetMerge.pause(show(at: 50_000), mark: still.mark, heardAt: t0.addingTimeInterval(4), now: t0.addingTimeInterval(4))
        XCTAssertFalse(played.long)
    }

    func testAPauseSeenHappeningCountsForItsAllowance() {
        // Heard playing 10 s in, then paused at 11 s, which the next answer (a second later) shows: the allowance from then.
        let allowance = FleetMerge.pausedLongAfter
        var mark = FleetMerge.pause(show(at: 10_000), mark: nil, heardAt: t0, now: t0).mark
        let paused = show(playing: false, at: 11_000)
        for (s, long) in [(1.0, false), (allowance, false), (allowance + 1, true), (allowance * 3, true)] {
            let judged = FleetMerge.pause(paused, mark: mark, heardAt: t0.addingTimeInterval(s), now: t0.addingTimeInterval(s))
            XCTAssertEqual(judged.long, long, "\(s - 1) s after it paused")
            mark = judged.mark
        }
    }

    func testAPauseMadeWhileTheAppSleptCountsFromWhereItStopped() {
        // Heard playing 1,000 s in; then the app slept for 40 minutes.
        let watched = FleetMerge.pause(show(at: 1_000_000), mark: nil, heardAt: t0, now: t0).mark
        let woke = t0.addingTimeInterval(40 * 60)
        // Paused 5 seconds before the app looked again (it played on for 39 min 55 s): its allowance is still to come.
        let allowance = FleetMerge.pausedLongAfter
        let lately = show(playing: false, at: 1_000_000 + 2_395_000)
        let first = FleetMerge.pause(lately, mark: watched, heardAt: woke, now: woke)
        XCTAssertFalse(first.long)
        XCTAssertFalse(FleetMerge.pause(lately, mark: first.mark, heardAt: woke.addingTimeInterval(allowance - 6), now: woke.addingTimeInterval(allowance - 6)).long)
        XCTAssertTrue(FleetMerge.pause(lately, mark: first.mark, heardAt: woke.addingTimeInterval(allowance - 5), now: woke.addingTimeInterval(allowance - 5)).long)
        // Paused a minute after the app last looked (and left behind after YouTube, say): long over by now.
        XCTAssertTrue(FleetMerge.pause(show(playing: false, at: 1_060_000), mark: watched, heardAt: woke, now: woke).long)
        // A pause never counts from later than the answer that shows it, whatever the position says (a skip forward).
        let skipped = FleetMerge.pause(show(playing: false, at: 5_000_000), mark: watched, heardAt: t0.addingTimeInterval(10), now: t0.addingTimeInterval(10))
        XCTAssertEqual(skipped.mark?.pausedAt, t0.addingTimeInterval(10))
        // No positions to go by: from the last answer that heard it playing.
        let live = FleetMerge.pause(NowPlaying(title: "News", playing: true), mark: nil, heardAt: t0, now: t0).mark
        XCTAssertTrue(FleetMerge.pause(NowPlaying(title: "News", playing: false), mark: live, heardAt: woke, now: woke).long)
    }

    func testTheNextEpisodeLoadingIsNotALeftover() {
        // Android counts only "playing" as playing: while the next video or episode loads, it reads as paused.
        let watching = FleetMerge.pause(show("Episode 4", at: 1_500_000, key: nil), mark: nil, heardAt: t0, now: t0)
        let loading = FleetMerge.pause(show("Episode 5", playing: false, at: 0, key: nil), mark: watching.mark,
                                       heardAt: t0.addingTimeInterval(1.5), now: t0.addingTimeInterval(1.5))
        XCTAssertFalse(loading.long)
        let started = FleetMerge.pause(show("Episode 5", at: 1_000, key: nil), mark: loading.mark,
                                       heardAt: t0.addingTimeInterval(3), now: t0.addingTimeInterval(3))
        XCTAssertFalse(started.long)
        // One that never starts still goes, its allowance on.
        let allowance = FleetMerge.pausedLongAfter
        let stuck = show("Episode 5", playing: false, at: 0, key: nil)
        XCTAssertFalse(FleetMerge.pause(stuck, mark: loading.mark, heardAt: t0.addingTimeInterval(allowance + 1), now: t0.addingTimeInterval(allowance + 1)).long)
        XCTAssertTrue(FleetMerge.pause(stuck, mark: loading.mark, heardAt: t0.addingTimeInterval(allowance + 1.5), now: t0.addingTimeInterval(allowance + 1.5)).long)
        // Partway through, or long after anything was heard playing: a session left behind.
        XCTAssertTrue(FleetMerge.pause(show("Orbit", playing: false, at: 1_200_000, key: nil), mark: watching.mark,
                                       heardAt: t0.addingTimeInterval(1.5), now: t0.addingTimeInterval(1.5)).long)
        XCTAssertTrue(FleetMerge.pause(stuck, mark: watching.mark, heardAt: t0.addingTimeInterval(3_600), now: t0.addingTimeInterval(3_600)).long)
    }

    func testAPauseKeepsItsClockWhileTheTVIsBrieflyOff() {
        var tv = FleetTV(id: "tv-k", name: "Kitchen", online: true, onScreen: true, playing: show(at: 10_000), version: nil, seen: nil,
                         link: "ok", health: nil, hubID: "tv-a", routeID: "tv-k", platform: nil)
        let watched = FleetMerge.pause(of: tv, mark: nil, heardAt: t0, tooOld: false, now: t0)
        tv.playing = show(playing: false, at: 12_000)
        let paused = FleetMerge.pause(of: tv, mark: watched.mark, heardAt: t0.addingTimeInterval(2), tooOld: false, now: t0.addingTimeInterval(2))
        XCTAssertFalse(paused.long)
        // One missed check: its hub passes it on as off (so playing nothing), then on again with the same pause.
        var off = tv
        off.online = false
        off.playing = nil
        let during = FleetMerge.pause(of: off, mark: paused.mark, heardAt: t0.addingTimeInterval(4), tooOld: false, now: t0.addingTimeInterval(4))
        XCTAssertEqual(during.mark, paused.mark)
        let back = FleetMerge.pause(of: tv, mark: during.mark, heardAt: t0.addingTimeInterval(6), tooOld: false, now: t0.addingTimeInterval(6))
        XCTAssertFalse(back.long, "still the pause from a few seconds ago")
        let allowance = FleetMerge.pausedLongAfter
        XCTAssertTrue(FleetMerge.pause(of: tv, mark: back.mark, heardAt: t0.addingTimeInterval(allowance + 2), tooOld: false, now: t0.addingTimeInterval(allowance + 2)).long)
        // Showing nothing only because what was heard is too old: kept too. On, with nothing playing: cleared.
        var quiet = tv
        quiet.playing = nil
        XCTAssertEqual(FleetMerge.pause(of: quiet, mark: back.mark, heardAt: t0, tooOld: true, now: t0.addingTimeInterval(60)).mark, back.mark)
        XCTAssertNil(FleetMerge.pause(of: quiet, mark: back.mark, heardAt: t0.addingTimeInterval(60), tooOld: false, now: t0.addingTimeInterval(60)).mark)
    }

    func testANewTitleStartsAfresh() {
        let watched = FleetMerge.pause(show(at: 10_000), mark: nil, heardAt: t0, now: t0).mark
        let left = FleetMerge.pause(show(playing: false, at: 11_000), mark: watched, heardAt: t0.addingTimeInterval(600), now: t0.addingTimeInterval(600))
        XCTAssertTrue(left.long)
        // Another title starts: playing, then paused a little later, on its own clock.
        let next = FleetMerge.pause(show("Ironwood", at: 1_000, key: "drive:m2"), mark: left.mark,
                                    heardAt: t0.addingTimeInterval(610), now: t0.addingTimeInterval(610))
        XCTAssertFalse(next.long)
        let nextPaused = FleetMerge.pause(show("Ironwood", playing: false, at: 5_000, key: "drive:m2"), mark: next.mark,
                                          heardAt: t0.addingTimeInterval(620), now: t0.addingTimeInterval(620))
        XCTAssertFalse(nextPaused.long)
        // A title that turns up already paused is a leftover, whatever was watched before it.
        let leftover = FleetMerge.pause(show("Orbit", playing: false, at: 9_000, key: "drive:m3"), mark: nextPaused.mark,
                                        heardAt: t0.addingTimeInterval(630), now: t0.addingTimeInterval(630))
        XCTAssertTrue(leftover.long)
        // Nothing playing clears the mark.
        let none = FleetMerge.pause(nil, mark: leftover.mark, heardAt: t0.addingTimeInterval(640), now: t0.addingTimeInterval(640))
        XCTAssertNil(none.mark)
        XCTAssertFalse(none.long)
    }

    func testNowPlayingIsOnlyWhatsOnAndNotLeftPaused() {
        var tv = FleetTV(id: "tv-a", name: "Living Room", online: true, onScreen: true, playing: show(at: 1_000), version: nil, seen: nil,
                         link: "ok", health: nil, hubID: "tv-a", routeID: "this", platform: nil)
        XCTAssertEqual(tv.nowPlaying?.title, "Midnight Harbor")
        tv.pausedLong = true
        XCTAssertNotNil(tv.nowPlaying, "playing counts whatever the pause clock said")
        tv.playing = show(playing: false, at: 1_000)
        XCTAssertNil(tv.nowPlaying, "paused too long")
        tv.pausedLong = false
        XCTAssertEqual(tv.nowPlaying?.isPlaying, false, "a recent pause still shows")
        tv.online = false
        XCTAssertNil(tv.nowPlaying)
        tv.online = true
        tv.link = "unpaired"
        XCTAssertNil(tv.nowPlaying)
    }

    func testAFilmsStartIsTimedFromTheTVsAnswers() {
        var watch = FilmStartWatch()
        func film(_ position: Double, length: Double = 0, playing: Bool = true) -> NowPlaying {
            NowPlaying(title: "Sinners", app: "Woodruff Family", playing: playing, position: position, duration: length, key: "drive:s1")
        }
        func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
        // Nothing playing, asked every 4 s; then the player opens at its place, still loading.
        XCTAssertNil(watch.note(tv: "tv-a", playing: nil, at: at(0)))
        XCTAssertNil(watch.note(tv: "tv-a", playing: nil, at: at(4)))
        XCTAssertNil(watch.note(tv: "tv-a", playing: film(600_000), at: at(8)))
        XCTAssertNil(watch.note(tv: "tv-a", playing: film(600_000), at: at(12)))
        // The film's length arrives 16 s after the player opened; its place is still where it was.
        XCTAssertNil(watch.note(tv: "tv-a", playing: film(600_000, length: 7_200_000), at: at(24)))
        // Playing: a second into it when asked 20 s after the opening, so it began 19 s after.
        let start = watch.note(tv: "tv-a", playing: film(601_000, length: 7_200_000), at: at(28))
        XCTAssertEqual(start?.title, "Sinners")
        XCTAssertEqual(start?.seconds ?? -1, 19, accuracy: 0.01)
        XCTAssertEqual(start?.lengthKnown ?? -1, 16, accuracy: 0.01)
        XCTAssertEqual(start?.within ?? -1, 4, accuracy: 0.01)
        // Said once.
        XCTAssertNil(watch.note(tv: "tv-a", playing: film(605_000, length: 7_200_000), at: at(32)))

        // A jump to where the film was left off isn't the film playing.
        var jump = FilmStartWatch()
        XCTAssertNil(jump.note(tv: "tv-a", playing: nil, at: at(0)))
        XCTAssertNil(jump.note(tv: "tv-a", playing: film(0), at: at(2)))
        XCTAssertNil(jump.note(tv: "tv-a", playing: film(3_000_000, length: 7_200_000), at: at(4)))
        XCTAssertEqual(jump.note(tv: "tv-a", playing: film(3_001_500, length: 7_200_000), at: at(6))?.seconds ?? -1, 2.5, accuracy: 0.01)

        // A film come upon part-way through (the TV not asked just before), or another app's title, isn't timed.
        var late = FilmStartWatch()
        XCTAssertNil(late.note(tv: "tv-a", playing: film(600_000, length: 7_200_000), at: at(0)))
        XCTAssertNil(late.note(tv: "tv-a", playing: film(604_000, length: 7_200_000), at: at(4)))
        var other = FilmStartWatch()
        let netflix = NowPlaying(title: "Stranger Things", app: "Netflix", playing: true, position: 5_000, duration: 3_000_000)
        XCTAssertNil(other.note(tv: "tv-a", playing: nil, at: at(0)))
        XCTAssertNil(other.note(tv: "tv-a", playing: netflix, at: at(2)))
        XCTAssertNil(other.note(tv: "tv-a", playing: NowPlaying(title: "Stranger Things", app: "Netflix", playing: true, position: 7_000, duration: 3_000_000), at: at(4)))
    }

    func testAnInputOnScreenIsNotSomethingPlaying() {
        // What an Android TV says while its HDMI 4 input shows the Apple TV: the TV's own input app, "playing" for as
        // long as the input is on, with no length.
        let input = NowPlaying(title: "Apple TV HDMI 4", app: "TV", playing: true, position: 0, duration: 0)
        XCTAssertTrue(input.isInput)
        XCTAssertTrue(NowPlaying(title: "Cable Box", app: "TV", playing: true).isInput, "the TV's input app, whatever the input is called")
        XCTAssertTrue(NowPlaying(title: "HDMI 2", app: "Inputs", playing: true).isInput)
        // Things that are playing: a film from the library, another app's title with a length, another app's live stream.
        XCTAssertFalse(show(at: 1_000).isInput)
        XCTAssertFalse(NowPlaying(title: "Stranger Things", app: "Netflix", playing: true, position: 5_000, duration: 3_000_000).isInput)
        XCTAssertFalse(NowPlaying(title: "Live: Rocket Launch", app: "YouTube", playing: true).isInput)
        // The merged list has such a TV on, playing nothing.
        let tvs = merge([hubA], ["tv-a": .answered([entry("this", "Living Room", playing: input)])])
        XCTAssertEqual(tvs["tv-a"]?.online, true)
        XCTAssertNil(tvs["tv-a"]?.playing)
        XCTAssertNil(tvs["tv-a"]?.nowPlaying)
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
