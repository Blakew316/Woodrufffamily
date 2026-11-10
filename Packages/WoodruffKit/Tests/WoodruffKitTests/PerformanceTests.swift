import XCTest
@testable import WoodruffKit

/// The shortcuts that keep the app quick: what the list keeps of when a TV was last heard, the library looked up
/// through an index (with the same answers as looking through it in order), and the Keychain's copy of its items.
final class PerformanceTests: XCTestCase {

    // MARK: When a TV was last heard

    private func tv(online: Bool, seen: Double?) -> FleetTV {
        FleetTV(id: "tv-k", name: "Kitchen", online: online, onScreen: false, playing: nil, version: nil, seen: seen,
                link: "ok", health: nil, hubID: "tv-a", routeID: "tv-k", platform: nil)
    }

    func testASeenThatMovesALittleIsKeptWhileTheTVStaysOn() {
        let before = tv(online: true, seen: 1_000_000)
        XCTAssertEqual(FleetMerge.steadySeen(1_002_000, online: true, before: before), 1_000_000)
        XCTAssertEqual(FleetMerge.steadySeen(1_029_999, online: true, before: before), 1_000_000)
        // An older word (another hub's) never takes it back either.
        XCTAssertEqual(FleetMerge.steadySeen(990_000, online: true, before: before), 1_000_000)
        // No word at all this time: what was kept stays.
        XCTAssertEqual(FleetMerge.steadySeen(nil, online: true, before: before), 1_000_000)
    }

    func testASeenThirtySecondsLaterMovesOn() {
        let before = tv(online: true, seen: 1_000_000)
        XCTAssertEqual(FleetMerge.steadySeen(1_030_000, online: true, before: before), 1_030_000)
        XCTAssertEqual(FleetMerge.steadySeen(1_500_000, online: true, before: before), 1_500_000)
    }

    func testATVThatIsOffOrWasOffShowsWhatItsHubSays() {
        // Gone off: "Seen …" goes by the answer.
        XCTAssertEqual(FleetMerge.steadySeen(1_002_000, online: false, before: tv(online: true, seen: 1_000_000)), 1_002_000)
        // Just come on, first heard, or never had one: the answer's.
        XCTAssertEqual(FleetMerge.steadySeen(1_002_000, online: true, before: tv(online: false, seen: 1_000_000)), 1_002_000)
        XCTAssertEqual(FleetMerge.steadySeen(1_002_000, online: true, before: nil), 1_002_000)
        XCTAssertEqual(FleetMerge.steadySeen(1_002_000, online: true, before: tv(online: true, seen: nil)), 1_002_000)
        XCTAssertNil(FleetMerge.steadySeen(nil, online: false, before: tv(online: true, seen: 1_000_000)))
    }

    func testMergingAnswersWhoseSeenCreepsKeepsTheListTheSame() {
        let hub = Hub(id: "tv-a", name: "Living Room", connection: TVConnection(base: URL(string: "http://192.168.1.10:8090")!, key: "a"))
        func answer(_ seen: Double) -> [String: HubAnswer] {
            [hub.id: .answered([
                TVListEntry(id: "this", name: "Living Room", online: true, onScreen: true, playing: nil, version: "2.0.1", seen: nil, link: "ok", health: nil),
                TVListEntry(id: "tv-k", name: "Kitchen", online: true, onScreen: true, playing: nil, version: "2.0.1", seen: seen, link: "ok", health: nil),
            ])]
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func merged(_ seen: Double, before: [FleetTV]) -> [FleetTV] {
            let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var list = FleetMerge.merge(hubs: [hub], answers: answer(seen), before: was, platforms: [:], now: now)
            // As `Fleet.rebuild` does.
            for i in list.indices { list[i].seen = FleetMerge.steadySeen(list[i].seen, online: list[i].online, before: was[list[i].id]) }
            return list
        }
        let first = merged(1_000_000, before: [])
        let second = merged(1_001_500, before: first)
        XCTAssertEqual(second, first, "nothing to redraw for a seen that moved a second and a half")
        let later = merged(1_031_000, before: second)
        XCTAssertEqual(later.first { $0.id == "tv-k" }?.seen, 1_031_000)
    }

    // MARK: The library, looked up through an index

    private func library() throws -> WatchHome {
        let json = """
        {"state": "ready",
         "featured": [{"id": "m1", "kind": "movie", "title": "Midnight Harbor", "poster": "/p/m1", "backdrop": "/b/m1"},
                      {"id": "m2", "kind": "movie", "title": "The Long Road", "poster": "/p/m2"}],
         "continue": [{"key": "drive:e7", "playTitle": "Northern Lights · S1E3", "titleId": "s1", "kind": "show",
                       "name": "Northern Lights", "poster": "/p/e7", "play": {"key": "drive:e7", "title": "Northern Lights"}},
                      {"key": "drive:x9", "playTitle": "Orphan", "kind": "movie", "name": "Orphan",
                       "play": {"key": "drive:x9", "title": "Orphan"}},
                      {"key": "drive:dup", "playTitle": "First Copy", "titleId": "m2", "kind": "movie", "name": "First Copy",
                       "play": {"key": "drive:dup", "title": "First Copy"}},
                      {"key": "drive:dup", "playTitle": "Second Copy", "titleId": "m1", "kind": "movie", "name": "Second Copy",
                       "play": {"key": "drive:dup", "title": "Second Copy"}}],
         "recent": [{"id": "m1", "kind": "movie", "title": "Midnight Harbor (copy)", "poster": "/p/other"},
                    {"id": "m3", "kind": "movie", "title": "Rocket 88", "backdrop": "/b/m3"}],
         "movies": {"count": 2, "items": [{"id": "m4", "kind": "movie", "title": "Midnight", "poster": "/p/m4"},
                                          {"id": "m2", "kind": "movie", "title": "The Long Road", "poster": "/p/m2b"}]},
         "shows": {"count": 1, "items": [{"id": "s1", "kind": "show", "title": "Northern Lights", "poster": "/p/s1", "backdrop": "/b/s1"}]}}
        """
        return try JSONDecoder().decode(WatchHome.self, from: Data(json.utf8))
    }

    /// The lookup as it was before the index: looking through the lists in order.
    private func inOrder(_ p: NowPlaying, _ lib: WatchHome) -> NowPlayingArtwork? {
        func simple(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let titles = (lib.featured ?? []) + (lib.recent ?? []) + (lib.movies?.items ?? []) + (lib.shows?.items ?? [])
        func title(_ id: String?) -> Title? { id.flatMap { id in titles.first { $0.id == id } } }
        let cont = lib.continue ?? []
        if let key = p.key, let c = cont.first(where: { $0.key == key }) {
            let t = title(c.titleId)
            return NowPlayingArtwork(poster: c.poster ?? t?.poster, backdrop: t?.backdrop, titleID: c.titleId)
        }
        if let key = p.key, key.hasPrefix("drive:"), let t = titles.first(where: { "drive:" + $0.id == key }) {
            return NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
        }
        let want = simple(String(p.title.split(separator: "·").first ?? Substring(p.title)))
        guard !want.isEmpty else { return nil }
        if let c = cont.first(where: { simple($0.name) == want || want.hasPrefix(simple($0.name)) }) {
            let t = title(c.titleId)
            return NowPlayingArtwork(poster: c.poster ?? t?.poster, backdrop: t?.backdrop, titleID: c.titleId)
        }
        if let t = titles.first(where: { simple($0.title) == want || want.hasPrefix(simple($0.title)) }) {
            return NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
        }
        return nil
    }

    func testTheIndexFindsWhatLookingThroughInOrderFinds() throws {
        let lib = try library()
        let index = ArtIndex(lib)
        let asked: [NowPlaying] = [
            NowPlaying(title: "Northern Lights · S1E3", key: "drive:e7"),      // in Continue Watching, by key
            NowPlaying(title: "Anything", key: "drive:x9"),                    // by key, no title behind it
            NowPlaying(title: "Whatever", key: "drive:dup"),                   // the first of two with one key
            NowPlaying(title: "Midnight Harbor", key: "drive:m1"),             // a title by its Drive key (first copy)
            NowPlaying(title: "The Long Road", key: "drive:m2"),
            NowPlaying(title: "Rocket 88", key: "drive:m3"),
            NowPlaying(title: "Midnight Harbor", key: nil),                    // by name: the first match in the lists' order
            NowPlaying(title: "midnight harbor", app: "Woodruff"),
            NowPlaying(title: "Northern Lights", key: "drive:unknown"),         // unknown key: by name
            NowPlaying(title: "Orphan · Director's Cut"),
            NowPlaying(title: "Nothing Like It"),
            NowPlaying(title: "· · ·"),                                         // nothing to look for
            NowPlaying(title: ""),
            NowPlaying(title: "Rocket 88: The Return"),
        ]
        for p in asked {
            XCTAssertEqual(index.artwork(for: p), inOrder(p, lib), "\(p.title) / \(p.key ?? "no key")")
        }
        XCTAssertEqual(ArtIndex.wanted(NowPlaying(title: "Orphan · Director's Cut")), "orphan")
        XCTAssertEqual(ArtIndex.wanted(NowPlaying(title: "· · ·")), "")
    }

    func testAnEmptyLibraryFindsNothing() throws {
        let lib = try JSONDecoder().decode(WatchHome.self, from: Data(#"{"state":"empty"}"#.utf8))
        XCTAssertNil(ArtIndex(lib).artwork(for: NowPlaying(title: "Midnight Harbor", key: "drive:m1")))
    }

    func testLibrariesCompareByWhatsInThem() throws {
        XCTAssertEqual(try library(), try library())
        var changed = try library()
        changed.featured?[0].poster = "/p/new"
        XCTAssertNotEqual(changed, try library())
    }

    // MARK: The Keychain's copy

    func testAReadIsKeptUntilAWrite() {
        let c = KeychainCache()
        XCTAssertFalse(c.value("a").hit)
        c.readFinished("a", "one", since: c.readStarted())
        XCTAssertEqual(c.value("a").hit, true)
        XCTAssertEqual(c.value("a").value, "one")
        c.writeStarted("a")
        XCTAssertFalse(c.value("a").hit, "nothing handed out while it's written")
        c.writeFinished("a", "two", ok: true)
        XCTAssertEqual(c.value("a").value, "two")
    }

    func testAWriteThatDidntGoThroughIsReadAfresh() {
        let c = KeychainCache()
        c.readFinished("a", "one", since: c.readStarted())
        c.writeStarted("a")
        c.writeFinished("a", "two", ok: false)
        XCTAssertFalse(c.value("a").hit)
    }

    func testAWriteOnItsWayIsHandedOutAtOnce() {
        let c = KeychainCache()
        c.readFinished("a", "one", since: c.readStarted())
        // Asked on the main thread: the new value is what's read from that moment, before the Keychain has it.
        c.writePending("a", "two")
        XCTAssertEqual(c.value("a").hit, true)
        XCTAssertEqual(c.value("a").value, "two")
        // Removed the same way: known not to be there.
        c.writePending("a", nil)
        XCTAssertEqual(c.value("a").hit, true)
        XCTAssertNil(c.value("a").value)
    }

    func testAWriteOnItsWayThatFailedIsReadAfresh() {
        let c = KeychainCache()
        c.writePending("a", "two")
        c.writeFailed("a", "two")
        XCTAssertFalse(c.value("a").hit, "forgotten, so the Keychain is asked next time")
        // A later write has replaced it meanwhile: that one stays.
        c.writePending("a", "two")
        c.writePending("a", "three")
        c.writeFailed("a", "two")
        XCTAssertEqual(c.value("a").value, "three")
    }

    func testAReadOverlappingAWriteOnItsWayIsntKept() {
        let c = KeychainCache()
        let stamp = c.readStarted()
        c.writePending("a", "new")
        c.readFinished("a", "old", since: stamp)
        XCTAssertEqual(c.value("a").value, "new")
    }

    func testAReadOverlappingAWriteIsntKept() {
        let c = KeychainCache()
        let stamp = c.readStarted()
        // Written while the read was out: what the read found may be the old value.
        c.writeStarted("a")
        c.writeFinished("a", "new", ok: true)
        c.readFinished("a", "old", since: stamp)
        XCTAssertEqual(c.value("a").value, "new")
        // The same for another item written meanwhile.
        let again = c.readStarted()
        c.writeStarted("b")
        c.writeFinished("b", nil, ok: true)
        c.readFinished("c", "stale?", since: again)
        XCTAssertFalse(c.value("c").hit)
    }

    func testNotThereIsBelievedOnlyBriefly() {
        let c = KeychainCache(missingFor: 30)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        c.readFinished("gone", nil, since: c.readStarted(), now: t0)
        c.readFinished("here", "value", since: c.readStarted(), now: t0)
        XCTAssertEqual(c.value("gone", now: t0.addingTimeInterval(29)).hit, true)
        XCTAssertNil(c.value("gone", now: t0.addingTimeInterval(29)).value)
        XCTAssertFalse(c.value("gone", now: t0.addingTimeInterval(30)).hit, "asked again after a while")
        XCTAssertEqual(c.value("here", now: t0.addingTimeInterval(3_600)).value, "value", "a value stays until it's written")
        // Removed here: "not there" for a while too.
        c.writeStarted("here")
        c.writeFinished("here", nil, ok: true, now: t0)
        XCTAssertEqual(c.value("here", now: t0.addingTimeInterval(10)).hit, true)
        XCTAssertFalse(c.value("here", now: t0.addingTimeInterval(31)).hit)
    }

    func testNotThereIsKeptTenMinutesByDefault() {
        let c = KeychainCache()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        c.readFinished("gone", nil, since: c.readStarted(), now: t0)
        XCTAssertEqual(c.value("gone", now: t0.addingTimeInterval(599)).hit, true)
        XCTAssertFalse(c.value("gone", now: t0.addingTimeInterval(600)).hit)
        // A write here ends it at once.
        c.readFinished("gone", nil, since: c.readStarted(), now: t0)
        c.writeStarted("gone")
        c.writeFinished("gone", "now", ok: true, now: t0)
        XCTAssertEqual(c.value("gone", now: t0.addingTimeInterval(1)).value, "now")
    }

    func testTheCacheIsSafeFromSeveralThreads() {
        let c = KeychainCache()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let account = "k\(i % 7)"
            if i % 3 == 0 {
                c.writeStarted(account)
                c.writeFinished(account, "v\(i)", ok: i % 2 == 0)
            } else {
                let stamp = c.readStarted()
                if !c.value(account).hit { c.readFinished(account, "r\(i)", since: stamp) }
            }
        }
        for i in 0..<7 { _ = c.value("k\(i)") }
    }
}
