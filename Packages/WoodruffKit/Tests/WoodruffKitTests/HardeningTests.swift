import XCTest
@testable import WoodruffKit

final class HardeningTests: XCTestCase {
    // MARK: Deco crypto (vectors from Python: pow(m, e, n), AES-128-CBC, MD5)

    static let n512 = "9ad29302a1c24547326c6a4e0b25a58bfe2ca403f321597630bb58bdc34db1f086c179cdf8cfb636790da284b8e2e5b3f06bd415ebcdaa2cd7d69a40676af1a7"
    static let d512 = "8003af74d4a59abce4ef89f29ffaefe852313d28dae6ef5eefaa6914f7210e08252fb28d9a5b7eaa12b476b868840d78308a93cd69658c63679a4336ddab3f69"
    static let c512 = "66381766d2d4e3c4bfc8ec1d412037f3b23b639fa325c121e144362b8013be6d994e7976d117917392240be72d2bf92ebbf3b31fadf5c9c38067e88cf0b43e25"
    static let n1024 = "83ebb09982d6781801315ba059ffd0534e06e4493e3489484c2b75b1533b6737121e0050180b434c2e2900b10040025227bb710a77af8060d919899dc79183316e29f848d1f12b4e2b2ddd30aa670a4c49959c1f04abc981546df3d8c0c034a59bef951f77779d0ea737854ae094e30796b9205b9a74f03789c5711bbfef9bdb"
    static let d1024 = "19ea94a023e71462cae13279f7145d8df0174483eb17911cc5f207c6156ee721178b134ea8da959702be8567408052b4671fd8de509306ea7fdc17800ab3d88cf62e966710c27d772deab4f201049c93c9e9e5a1b556a908a7718bf4b0b82b4891d79abd263b0c3710e68a459185660ab8fc78571e8771e4894cd940d59f33d9"
    static let c1024 = "3cccf50854e1294de82bd47859089096b6f42b0c6fcdf8c30b09d2249d93296db09922b2335f9e675d075392ed47e84c9ba687c076e64f831464571db87f18637361d631335c47faa5dfc8fd4b10b1f7640a24ece08ab6706e7a015eb9f4eb85b24d48ffc87a859f3d27c1aaab8505b60315ad86c995174dccd2f2006d6b52b8"

    #if canImport(CommonCrypto)
    func testModularPowerMatchesPython() throws {
        let m = BigUInt(bytes: Array("hello deco".utf8))
        let e = try XCTUnwrap(BigUInt(hex: "10001"))
        for (n, c) in [(Self.n512, Self.c512), (Self.n1024, Self.c1024)] {
            let nn = try XCTUnwrap(BigUInt(hex: n))
            XCTAssertEqual(m.power(e, mod: nn), BigUInt(hex: c))
        }
    }

    /// Encrypt with the public key, decrypt with the private one: PKCS#1 v1.5 padding is right in every block.
    func testRSARoundTripsAcrossBlocks() throws {
        for (n, d) in [(Self.n512, Self.d512), (Self.n1024, Self.d1024)] {
            let nn = try XCTUnwrap(BigUInt(hex: n)), dd = try XCTUnwrap(BigUInt(hex: d))
            let k = (nn.bitWidth + 7) / 8
            let message = Data((0..<(k * 2 + 7)).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) })   // several blocks
            let hex = try XCTUnwrap(DecoCrypto.rsa(nHex: n, eHex: "10001", message))
            XCTAssertEqual(hex.count % (k * 2), 0)
            var out = Data()
            var rest = Substring(hex)
            while !rest.isEmpty {
                let block = try XCTUnwrap(BigUInt(hex: String(rest.prefix(k * 2))))
                rest = rest.dropFirst(k * 2)
                let p = block.power(dd, mod: nn).bytes(length: k)
                XCTAssertEqual(p[0], 0); XCTAssertEqual(p[1], 2)
                let sep = try XCTUnwrap(p.dropFirst(2).firstIndex(of: 0))
                XCTAssertGreaterThanOrEqual(sep - 2, 8)
                XCTAssertFalse(p[2..<sep].contains(0))
                out.append(contentsOf: p[(sep + 1)...])
            }
            XCTAssertEqual(out, message)
        }
    }

    func testAESMatchesPython() throws {
        let enc = try XCTUnwrap(DecoCrypto.aes(true, key: "1234567890123456", iv: "6543210987654321", Data(#"{"operation":"read"}"#.utf8)))
        XCTAssertEqual(enc.base64EncodedString(), "fRWsWuU+ZK9hMddivIRSDu2X77PSFh50KGPf9hkkHag=")
        let dec = try XCTUnwrap(DecoCrypto.aes(false, key: "1234567890123456", iv: "6543210987654321", enc))
        XCTAssertEqual(String(decoding: dec, as: UTF8.self), #"{"operation":"read"}"#)
    }

    func testMD5AndDigits() {
        XCTAssertEqual(DecoCrypto.md5Hex("adminsecret"), "71a4a17a658b90a7f847585721b5a217")
        for _ in 0..<50 { let d = DecoCrypto.digits(); XCTAssertEqual(d.count, 16); XCTAssertTrue(d.allSatisfy(\.isNumber)) }
    }

    func testBigUIntStress() {
        // (a*b) % m against UInt64 arithmetic for many random small values.
        for _ in 0..<2000 {
            let a = UInt64.random(in: 0...UInt64(UInt32.max)), b = UInt64.random(in: 0...UInt64(UInt32.max))
            let m = UInt64.random(in: 1...UInt64(UInt32.max))
            let r = (BigUInt([UInt32(a)]) * BigUInt([UInt32(b)])) % BigUInt([UInt32(m)])
            XCTAssertEqual(r, BigUInt([UInt32((a * b) % m)]))
        }
    }
    #endif

    // MARK: Settings sync merging

    func testEntriesMergeKeepsBothDevicesChanges() {
        let base = #"{"a":"Kitchen","b":"Den"}"#
        // Phone renames a; Mac renames b, a moment later.
        let phone = #"{"a":"Pantry","b":"Den"}"#, mac = #"{"a":"Kitchen","b":"Office"}"#
        let ps = SyncMerge.stampEntries(old: base, new: phone, stamps: [:], now: 100)
        let ms = SyncMerge.stampEntries(old: base, new: mac, stamps: [:], now: 101)
        let m1 = SyncMerge.mergeEntries(local: phone, localStamps: ps, remote: mac, remoteStamps: ms)
        let m2 = SyncMerge.mergeEntries(local: mac, localStamps: ms, remote: phone, remoteStamps: ps)
        XCTAssertEqual(m1.value, #"{"a":"Pantry","b":"Office"}"#)
        XCTAssertEqual(m1.value, m2.value)   // both devices end the same
        XCTAssertEqual(m1.stamps, m2.stamps)
    }

    func testEntryRemovalWinsOverOlderCopy() {
        let old = #"{"a":"x","b":"y"}"#
        let removed = #"{"b":"y"}"#
        let st = SyncMerge.stampEntries(old: old, new: removed, stamps: ["a": 50], now: 60)
        XCTAssertEqual(st["a"], -60)
        let m = SyncMerge.mergeEntries(local: old, localStamps: ["a": 50], remote: removed, remoteStamps: st)
        XCTAssertEqual(m.value, removed)
        // A newer re-add beats the removal.
        let m2 = SyncMerge.mergeEntries(local: old, localStamps: ["a": 70], remote: removed, remoteStamps: st)
        XCTAssertEqual(m2.value, old)
    }

    func testAutomaticChangeNeverPutsBackAChangeMadeElsewhere() {
        // A TV's details: one entry, stamped 100 on both devices. The phone renames the TV at 200; the Mac, not having
        // that yet, follows the TV to a new address by itself at 205.
        let base = #"{"tv1":{"lastHost":"192.168.1.20","platform":"android"}}"#
        let phone = #"{"tv1":{"alias":"Kitchen","lastHost":"192.168.1.20","platform":"android"}}"#
        let mac = #"{"tv1":{"lastHost":"192.168.1.33","platform":"android"}}"#
        func entry(_ s: String) -> String { SyncMerge.canonical((SyncMerge.object(s) as? [String: Any])?["tv1"] ?? [:]) ?? "" }
        let ps = SyncMerge.stampEntries(old: base, new: phone, stamps: ["tv1": 100], now: 200)
        let ms = SyncMerge.stampEntries(old: base, new: mac, stamps: ["tv1": 100], now: 205,
                                        automatic: ["tv1": (from: entry(base), to: entry(mac))])
        XCTAssertEqual(ms["tv1"], SyncMerge.stampAfter(100))
        let m1 = SyncMerge.mergeEntries(local: phone, localStamps: ps, remote: mac, remoteStamps: ms)
        let m2 = SyncMerge.mergeEntries(local: mac, localStamps: ms, remote: phone, remoteStamps: ps)
        XCTAssertEqual(m1.value, phone)   // the name stays
        XCTAssertEqual(m2.value, phone)
        // With nothing changed elsewhere, the Mac's change still reaches a device that has the details as they were.
        XCTAssertEqual(SyncMerge.mergeEntries(local: base, localStamps: ["tv1": 100], remote: mac, remoteStamps: ms).value, mac)
        // Changed by a person here as well since the last look: stamped as new.
        let both = #"{"tv1":{"alias":"Den","lastHost":"192.168.1.33","platform":"android"}}"#
        XCTAssertEqual(SyncMerge.stampEntries(old: base, new: both, stamps: ["tv1": 100], now: 205,
                                              automatic: ["tv1": (from: entry(base), to: entry(mac))])["tv1"], 205)
    }

    func testListMergeKeepsTheFamilysItemsAndOnesAddedElsewhere() throws {
        func ids(_ v: String) -> [String] { ((SyncMerge.object(v) as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } }
        let family = #"[{"id":"movie-night","name":"Movie Night (ours)"},{"id":"bedtime","name":"Bedtime"},{"id":"s1","name":"Dinner"}]"#
        let familyStamps: [String: Double] = ["s1": 300]
        // A new device saves its first list (its built-in two, and one it added) before the family's copy came: it
        // only fills in, and is the newer list as a whole.
        let fresh = #"[{"id":"movie-night","name":"Movie Night"},{"id":"bedtime","name":"Bedtime"},{"id":"s9","name":"Reading"}]"#
        let freshStamps = SyncMerge.stampItems(old: "", new: fresh, stamps: [:], now: 0.5)
        let a = try XCTUnwrap(SyncMerge.mergeItems(local: family, localStamps: familyStamps, localStamp: 300,
                                                   remote: fresh, remoteStamps: freshStamps, remoteStamp: 400))
        let b = try XCTUnwrap(SyncMerge.mergeItems(local: fresh, localStamps: freshStamps, localStamp: 400,
                                                   remote: family, remoteStamps: familyStamps, remoteStamp: 300))
        XCTAssertEqual(a.value, b.value)
        XCTAssertEqual(a.stamps, b.stamps)
        XCTAssertEqual(Set(ids(a.value)), ["movie-night", "bedtime", "s1", "s9"])
        XCTAssertTrue(a.value.contains("Movie Night (ours)"))
        XCTAssertGreaterThan(a.stamp, 400)   // newer than both, so a build that keeps the list whole takes it
        // Merging again changes nothing.
        let again = try XCTUnwrap(SyncMerge.mergeItems(local: a.value, localStamps: a.stamps, localStamp: a.stamp,
                                                       remote: fresh, remoteStamps: freshStamps, remoteStamp: 400))
        XCTAssertEqual(again.value, a.value)
        XCTAssertEqual(again.stamp, a.stamp)
        // Rooms are names: one added on each device, both stay.
        let r = try XCTUnwrap(SyncMerge.mergeItems(local: #"["Den","Gym"]"#, localStamps: ["Gym": 10], localStamp: 10,
                                                   remote: #"["Den","Office"]"#, remoteStamps: ["Office": 11], remoteStamp: 11))
        XCTAssertEqual(r.value, #"["Den","Office","Gym"]"#)
    }

    func testListItemDeletedStaysDeleted() throws {
        let base = #"[{"id":"s1","name":"Dinner"},{"id":"s2","name":"Party"}]"#
        let deleted = #"[{"id":"s1","name":"Dinner"}]"#
        let ds = SyncMerge.stampItems(old: base, new: deleted, stamps: [:], now: 600)
        XCTAssertEqual(ds["s2"], -600)
        // Against a copy that still has it, and one that's newer as a whole (another scene changed later).
        let m1 = try XCTUnwrap(SyncMerge.mergeItems(local: base, localStamps: [:], localStamp: 100, remote: deleted, remoteStamps: ds, remoteStamp: 600))
        XCTAssertEqual(m1.value, deleted)
        let later = #"[{"id":"s1","name":"Dinner!"},{"id":"s2","name":"Party"}]"#
        let ls = SyncMerge.stampItems(old: base, new: later, stamps: [:], now: 700)
        let m2 = try XCTUnwrap(SyncMerge.mergeItems(local: deleted, localStamps: ds, localStamp: 600, remote: later, remoteStamps: ls, remoteStamp: 700))
        XCTAssertEqual(m2.value, #"[{"id":"s1","name":"Dinner!"}]"#)
        // Not a list of items with ids: left to be taken whole.
        XCTAssertNil(SyncMerge.mergeItems(local: #"{"a":1}"#, localStamps: [:], localStamp: 1, remote: base, remoteStamps: [:], remoteStamp: 2))
    }

    func testListMergeStressConverges() {
        // Devices adding, changing, deleting and reordering at random, merged in random orders, all end identical, and
        // every item ends as its last change anywhere said (other than a device's very first save, which fills in).
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var copies: [(value: String, stamps: [String: Double], stamp: Double)] = Array(repeating: ("", [:], 0), count: 4)
            var lastChange: [String: String?] = [:]
            var clock = 1.0
            for _ in 0..<12 {
                let i = Int.random(in: 0..<4, using: &rng)
                var list = (SyncMerge.object(copies[i].value) as? [[String: Any]]) ?? []
                let id = ["a", "b", "c", "d"].randomElement(using: &rng)!
                let at = list.firstIndex { ($0["id"] as? String) == id }
                var name: String?? = .none
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: if let at { list.remove(at: at); name = .some(nil) }
                case 1: let n = "n\(Int.random(in: 0..<50, using: &rng))"
                        if let at { list[at]["name"] = n } else { list.append(["id": id, "name": n]) }
                        name = .some(n)
                default: if list.count > 1 { list.swapAt(0, list.count - 1) }
                }
                let new = SyncMerge.canonical(list) ?? "[]"
                guard new != copies[i].value else { continue }
                clock += 1
                let first = copies[i].value.isEmpty
                if let name, !first { lastChange[id] = name } else if name != nil { lastChange[id] = nil }
                copies[i] = (new, SyncMerge.stampItems(old: copies[i].value, new: new, stamps: copies[i].stamps, now: first ? 0.5 : clock), clock)
            }
            for _ in 0..<4 {
                for i in (0..<4).shuffled(using: &rng) {
                    for j in (0..<4).shuffled(using: &rng) where i != j {
                        guard let m = SyncMerge.mergeItems(local: copies[i].value, localStamps: copies[i].stamps, localStamp: copies[i].stamp,
                                                           remote: copies[j].value, remoteStamps: copies[j].stamps, remoteStamp: copies[j].stamp) else { continue }
                        copies[i] = (m.value, m.stamps, m.stamp)
                    }
                }
            }
            XCTAssertEqual(Set(copies.map(\.value)).count, 1)
            let final = (SyncMerge.object(copies[0].value) as? [[String: Any]]) ?? []
            for (id, name) in lastChange {
                XCTAssertEqual(final.first { ($0["id"] as? String) == id }?["name"] as? String, name, "item \(id)")
            }
        }
    }

    func testUnstampedEntriesFillInWithoutOverwriting() {
        // A new device's old settings (no stamps) never replace an entry the family set.
        let m = SyncMerge.mergeEntries(local: #"{"a":"old","c":"mine"}"#, localStamps: [:],
                                       remote: #"{"a":"family"}"#, remoteStamps: ["a": 500])
        XCTAssertEqual(m.value, #"{"a":"family","c":"mine"}"#)
    }

    func testLayoutFavouritesMergeBothWays() {
        let a = #"{"favorites":["cam1","tv1"],"favoriteStamps":{"tv1":10},"sections":["tvs"]}"#
        let b = #"{"favorites":["cam1","lamp"],"favoriteStamps":{"lamp":20,"tv1":-15},"sections":["cameras"]}"#
        let m = SyncMerge.mergeLayout(local: a, remote: b, remoteNewer: true)
        let o = SyncMerge.object(m) as? [String: Any]
        XCTAssertEqual(o?["favorites"] as? [String], ["cam1", "lamp"])   // tv1 removed later on b
        XCTAssertEqual(o?["sections"] as? [String], ["cameras"])        // newer layout's sections
        // Merging again changes nothing (no ping-pong).
        XCTAssertEqual(SyncMerge.mergeLayout(local: m, remote: b, remoteNewer: true), m)
        XCTAssertEqual(SyncMerge.favoritesPart(m), SyncMerge.favoritesPart(SyncMerge.mergeLayout(local: b, remote: m, remoteNewer: false)))
    }

    func testSyncMergeStressConverges() {
        // Many devices making random edits, merged in random orders, all end identical.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var copies: [(String, [String: Double])] = Array(repeating: ("{}", [:]), count: 4)
            var clock = 1.0
            for _ in 0..<12 {
                let i = Int.random(in: 0..<4, using: &rng)
                var dict = SyncMerge.object(copies[i].0) as? [String: String] ?? [:]
                let key = ["a", "b", "c", "d"].randomElement(using: &rng)!
                if Bool.random(using: &rng) { dict[key] = "v\(Int.random(in: 0..<9, using: &rng))" } else { dict[key] = nil }
                let new = SyncMerge.canonical(dict)!
                clock += 1
                copies[i] = (new, SyncMerge.stampEntries(old: copies[i].0, new: new, stamps: copies[i].1, now: clock))
            }
            // Gossip until stable, in a random order.
            for _ in 0..<4 {
                for i in (0..<4).shuffled(using: &rng) {
                    for j in (0..<4).shuffled(using: &rng) where i != j {
                        let m = SyncMerge.mergeEntries(local: copies[i].0, localStamps: copies[i].1, remote: copies[j].0, remoteStamps: copies[j].1)
                        copies[i] = (m.value, m.stamps)
                    }
                }
            }
            XCTAssertEqual(Set(copies.map(\.0)).count, 1)
        }
    }

    func testEntryTiesEndTheSameEitherWayRound() {
        // Two old copies (no stamps) with different names for the same thing, handed across at the same moment:
        // both devices keep the same one (never each taking the other's, which swaps them back and forth).
        let a = #"{"x":"Kitchen"}"#, b = #"{"x":"Den"}"#
        let m1 = SyncMerge.mergeEntries(local: a, localStamps: [:], remote: b, remoteStamps: [:])
        let m2 = SyncMerge.mergeEntries(local: b, localStamps: [:], remote: a, remoteStamps: [:])
        XCTAssertEqual(m1.value, m2.value)
        XCTAssertEqual(m1.stamps, m2.stamps)
        // The same stamp on both sides with different values: the same answer too, and merging it again changes nothing.
        let m3 = SyncMerge.mergeEntries(local: a, localStamps: ["x": 50], remote: b, remoteStamps: ["x": 50])
        let m4 = SyncMerge.mergeEntries(local: b, localStamps: ["x": 50], remote: a, remoteStamps: ["x": 50])
        XCTAssertEqual(m3.value, m4.value)
        XCTAssertEqual(SyncMerge.mergeEntries(local: m3.value, localStamps: m3.stamps, remote: b, remoteStamps: ["x": 50]).value, m3.value)
    }

    func testOldCopiesWithTiesConverge() {
        // Devices that start with different old (unstamped) copies, then make changes, all end identical.
        var rng = SystemRandomNumberGenerator()
        let keys = ["a", "b", "c", "d"]
        for _ in 0..<200 {
            var copies: [(String, [String: Double])] = []
            for _ in 0..<4 {
                var dict: [String: String] = [:]
                for k in keys {
                    if Bool.random(using: &rng) { dict[k] = "o\(Int.random(in: 0..<3, using: &rng))" }
                }
                copies.append((SyncMerge.canonical(dict) ?? "{}", [:]))
            }
            var clock = 1.0
            for _ in 0..<8 {
                let i = Int.random(in: 0..<4, using: &rng)
                var dict = SyncMerge.object(copies[i].0) as? [String: String] ?? [:]
                let key = keys[Int.random(in: 0..<keys.count, using: &rng)]
                if Bool.random(using: &rng) { dict[key] = "v\(Int.random(in: 0..<9, using: &rng))" } else { dict[key] = nil }
                let new = SyncMerge.canonical(dict) ?? "{}"
                clock += 1
                copies[i] = (new, SyncMerge.stampEntries(old: copies[i].0, new: new, stamps: copies[i].1, now: clock))
            }
            for _ in 0..<4 {
                for i in (0..<4).shuffled(using: &rng) {
                    for j in (0..<4).shuffled(using: &rng) where i != j {
                        let m = SyncMerge.mergeEntries(local: copies[i].0, localStamps: copies[i].1, remote: copies[j].0, remoteStamps: copies[j].1)
                        copies[i] = (m.value, m.stamps)
                    }
                }
            }
            XCTAssertEqual(Set(copies.map(\.0)).count, 1)
        }
    }

    func testLayoutPartsMergeBothDevicesChanges() throws {
        let base = #"{"favorites":["cam1"],"groupByRoom":true,"hiddenItems":[],"order":{},"pinnedRooms":["Kitchen"],"sections":["rooms","tvs"],"version":2}"#
        let start = SyncMerge.uniformStamps(base, 5)
        // The phone hides a tile; the Mac pins a room a moment later; neither has seen the other's change yet.
        let phone = #"{"favorites":["cam1"],"groupByRoom":true,"hiddenItems":["tv1"],"order":{},"pinnedRooms":["Kitchen"],"sections":["rooms","tvs"],"version":2}"#
        let mac = #"{"favorites":["cam1"],"groupByRoom":true,"hiddenItems":[],"order":{},"pinnedRooms":["Kitchen","Den"],"sections":["rooms","tvs"],"version":2}"#
        let ps = SyncMerge.stampEntries(old: base, new: phone, stamps: start, now: 10)
        let ms = SyncMerge.stampEntries(old: base, new: mac, stamps: start, now: 11)
        let a = SyncMerge.mergeLayout(local: phone, localStamps: ps, remote: mac, remoteStamps: ms)
        let b = SyncMerge.mergeLayout(local: mac, localStamps: ms, remote: phone, remoteStamps: ps)
        XCTAssertEqual(a.value, b.value)
        XCTAssertEqual(a.stamps, b.stamps)
        let o = try XCTUnwrap(SyncMerge.object(a.value) as? [String: Any])
        XCTAssertEqual(o["hiddenItems"] as? [String], ["tv1"])
        XCTAssertEqual(o["pinnedRooms"] as? [String], ["Kitchen", "Den"])
        // Merging again changes nothing (no back and forth).
        XCTAssertEqual(SyncMerge.mergeLayout(local: a.value, localStamps: a.stamps, remote: mac, remoteStamps: ms).value, a.value)
    }

    func testLayoutFavouritesMergeOneByOneEitherWayRound() throws {
        let a = #"{"favorites":["cam1","tv1"],"favoriteStamps":{"tv1":10},"sections":["tvs"]}"#
        let b = #"{"favorites":["cam1","lamp"],"favoriteStamps":{"lamp":20,"tv1":-15},"sections":["cameras"]}"#
        let sa: [String: Double] = ["favorites": 10, "favoriteStamps": 10, "sections": 3]
        let sb: [String: Double] = ["favorites": 20, "favoriteStamps": 20, "sections": 4]
        let m1 = SyncMerge.mergeLayout(local: a, localStamps: sa, remote: b, remoteStamps: sb)
        let m2 = SyncMerge.mergeLayout(local: b, localStamps: sb, remote: a, remoteStamps: sa)
        XCTAssertEqual(m1.value, m2.value)
        let o = try XCTUnwrap(SyncMerge.object(m1.value) as? [String: Any])
        XCTAssertEqual(o["favorites"] as? [String], ["cam1", "lamp"])   // tv1 removed later on b
        XCTAssertEqual(o["sections"] as? [String], ["cameras"])        // b changed its sections later
        // One added on each device, neither seen by the other: both stay, the same on both.
        let c = #"{"favorites":["cam1","tv2"],"favoriteStamps":{"tv2":30}}"#
        let d = #"{"favorites":["cam1","fan"],"favoriteStamps":{"fan":31}}"#
        let sc: [String: Double] = ["favorites": 30, "favoriteStamps": 30]
        let sd: [String: Double] = ["favorites": 31, "favoriteStamps": 31]
        let m3 = SyncMerge.mergeLayout(local: c, localStamps: sc, remote: d, remoteStamps: sd)
        let m4 = SyncMerge.mergeLayout(local: d, localStamps: sd, remote: c, remoteStamps: sc)
        XCTAssertEqual(m3.value, m4.value)
        let favs = try XCTUnwrap((SyncMerge.object(m3.value) as? [String: Any])?["favorites"] as? [String])
        XCTAssertEqual(Set(favs), ["cam1", "tv2", "fan"])
    }

    func testLayoutFromBeforePartByPartKeepsTheNewerLayout() throws {
        // A copy kept whole (stamp 50) against this device's, kept whole until now (stamp 40): the other layout is
        // the newer one, so every part comes from it; favourites still merge one by one.
        let mine = #"{"favorites":["cam1"],"sections":["tvs","rooms"]}"#
        let theirs = #"{"favorites":["tv1"],"favoriteStamps":{"tv1":45},"sections":["rooms","tvs"]}"#
        let m = SyncMerge.mergeLayout(local: mine, localStamps: SyncMerge.uniformStamps(mine, 40),
                                      remote: theirs, remoteStamps: SyncMerge.uniformStamps(theirs, 50))
        let o = try XCTUnwrap(SyncMerge.object(m.value) as? [String: Any])
        XCTAssertEqual(o["sections"] as? [String], ["rooms", "tvs"])
        XCTAssertEqual(o["favorites"] as? [String], ["tv1", "cam1"])
    }

    func testLayoutMergeStressConverges() throws {
        // Three devices changing parts of the layout and toggling favourites, merged in random orders, all end the same.
        var rng = SystemRandomNumberGenerator()
        let parts = ["sections", "hiddenItems", "pinnedRooms", "groupByRoom"]
        let ids = ["a", "b", "c", "d"]
        for _ in 0..<150 {
            let empty: (String, [String: Double]) = (#"{"favorites":[],"version":2}"#, ["favorites": 1, "version": 1])
            var copies = Array(repeating: empty, count: 3)
            var clock = 10.0
            for _ in 0..<10 {
                let i = Int.random(in: 0..<3, using: &rng)
                var o = try XCTUnwrap(SyncMerge.object(copies[i].0) as? [String: Any])
                clock += 1
                if Bool.random(using: &rng) {
                    // A favourite added or removed, as HomeLayout.toggleFavorite does it.
                    let id = ids[Int.random(in: 0..<ids.count, using: &rng)]
                    var favs = o["favorites"] as? [String] ?? []
                    var stamps = o["favoriteStamps"] as? [String: Double] ?? [:]
                    if let at = favs.firstIndex(of: id) { favs.remove(at: at); stamps[id] = -clock } else { favs.append(id); stamps[id] = clock }
                    o["favorites"] = favs
                    o["favoriteStamps"] = stamps
                } else {
                    o[parts[Int.random(in: 0..<parts.count, using: &rng)]] = ["v\(Int.random(in: 0..<5, using: &rng))"]
                }
                let new = try XCTUnwrap(SyncMerge.canonical(o))
                copies[i] = (new, SyncMerge.stampEntries(old: copies[i].0, new: new, stamps: copies[i].1, now: clock))
            }
            for _ in 0..<4 {
                for i in (0..<3).shuffled(using: &rng) {
                    for j in (0..<3).shuffled(using: &rng) where i != j {
                        let m = SyncMerge.mergeLayout(local: copies[i].0, localStamps: copies[i].1, remote: copies[j].0, remoteStamps: copies[j].1)
                        copies[i] = (m.value, m.stamps)
                    }
                }
            }
            XCTAssertEqual(Set(copies.map(\.0)).count, 1)
        }
    }

    func testTileWidthsMergeTileByTile() throws {
        // Two Macs resizing different Favorites tiles at about the same time both keep their size.
        let base = #"{"cam1":320,"tv1":400}"#
        let a = #"{"cam1":480,"tv1":400}"#, b = #"{"cam1":320,"tv1":520.5}"#
        let sa = SyncMerge.stampEntries(old: base, new: a, stamps: [:], now: 100.25)
        let sb = SyncMerge.stampEntries(old: base, new: b, stamps: [:], now: 100.5)
        let m1 = SyncMerge.mergeEntries(local: a, localStamps: sa, remote: b, remoteStamps: sb)
        let m2 = SyncMerge.mergeEntries(local: b, localStamps: sb, remote: a, remoteStamps: sa)
        XCTAssertEqual(m1.value, m2.value)
        let o = try XCTUnwrap(SyncMerge.object(m1.value) as? [String: Double])
        XCTAssertEqual(o["cam1"], 480)
        XCTAssertEqual(o["tv1"], 520.5)
    }

    func testPairedTVsMergeOneByOne() throws {
        // A TV paired on the phone and another forgotten on the Mac: the family's list ends up with both changes.
        let base = #"{"tv1":{"base":"http://10.0.0.5:8090","key":"k1","name":"Den"},"tv2":{"base":"http://10.0.0.6:8090","key":"k2","name":"Kitchen"}}"#
        let phone = #"{"tv1":{"base":"http://10.0.0.5:8090","key":"k1","name":"Den"},"tv2":{"base":"http://10.0.0.6:8090","key":"k2","name":"Kitchen"},"tv3":{"base":"http://10.0.0.7:8090","key":"k3","name":"Office"}}"#
        let mac = #"{"tv1":{"base":"http://10.0.0.5:8090","key":"k1","name":"Den"}}"#
        let ps = SyncMerge.stampEntries(old: base, new: phone, stamps: [:], now: 200)
        let ms = SyncMerge.stampEntries(old: base, new: mac, stamps: [:], now: 201)
        let m = SyncMerge.mergeEntries(local: phone, localStamps: ps, remote: mac, remoteStamps: ms)
        let o = try XCTUnwrap(SyncMerge.object(m.value) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["tv1", "tv3"])
        XCTAssertEqual(m.stamps["tv2"], -201)   // the removal travels on
        // Paired again with a new key (the TV was reset): the new key replaces the old one.
        let renewed = #"{"tv1":{"base":"http://10.0.0.5:8090","key":"k9","name":"Den"}}"#
        let rs = SyncMerge.stampEntries(old: mac, new: renewed, stamps: ms, now: 300)
        let m2 = SyncMerge.mergeEntries(local: m.value, localStamps: m.stamps, remote: renewed, remoteStamps: rs)
        let merged = try XCTUnwrap(SyncMerge.object(m2.value) as? [String: Any])
        XCTAssertEqual((merged["tv1"] as? [String: Any])?["key"] as? String, "k9")
        XCTAssertNotNil(merged["tv3"])
    }

    func testUniformStamps() {
        XCTAssertEqual(SyncMerge.uniformStamps(#"{"a":1,"b":[2]}"#, 7), ["a": 7, "b": 7])
        XCTAssertEqual(SyncMerge.uniformStamps("", 7), [:])
        XCTAssertEqual(SyncMerge.uniformStamps(#"{"a":1}"#, 0), [:])
    }

    func testStampsReadBackExactlyFromJSON() throws {
        // A stamp (or a setting's text) that came back a hair different would look like a change, and devices would
        // hand it back and forth for ever.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let t = SyncMerge.stampNow(Date(timeIntervalSince1970: Double.random(in: 1_600_000_000...2_100_000_000, using: &rng)))
            let item: [String: Any] = ["t": t, "e": ["a": t, "b": -t]]
            let d = try JSONSerialization.data(withJSONObject: item)
            let back = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
            XCTAssertEqual((back["t"] as? NSNumber)?.doubleValue, t)
            let e = (back["e"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            XCTAssertEqual(e, ["a": t, "b": -t])
            let text = try XCTUnwrap(SyncMerge.canonical(item))
            XCTAssertEqual(SyncMerge.object(text).flatMap { SyncMerge.canonical($0) }, text)
        }
        XCTAssertEqual(SyncMerge.stampNow(Date(timeIntervalSince1970: 1_700_000_000.123_456)), 1_700_000_000.123)
    }

    // MARK: The family code

    func testFamilyCodeReadsBackAsTyped() throws {
        for _ in 0..<200 {
            let code = FamilyCode.generate()
            XCTAssertEqual(code.count, 25)
            XCTAssertEqual(FamilyCode.normalize(code), code)
            let shown = FamilyCode.formatted(code)
            XCTAssertEqual(shown.split(separator: "-").map(\.count), [5, 5, 5, 5, 5])
            // Typed in lower case, with spaces, O for 0 and L for 1.
            let typed = shown.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
            XCTAssertEqual(FamilyCode.normalize(typed), code)
        }
        XCTAssertNil(FamilyCode.normalize(""))
        XCTAssertNil(FamilyCode.normalize("ABCDE"))
    }

    func testFamilyCodeCatchesOneWrongCharacter() {
        let alphabet = FamilyCode.alphabet
        for _ in 0..<50 {
            let code = Array(FamilyCode.generate())
            for i in 0..<code.count {
                for ch in alphabet where ch != code[i] {
                    var typo = code
                    typo[i] = ch
                    XCTAssertNil(FamilyCode.normalize(String(typo)))
                }
            }
        }
    }

    #if canImport(CryptoKit)
    func testFamilyKeysDependOnTheCode() {
        let a = FamilyCode.generate(), b = FamilyCode.generate()
        XCTAssertEqual(FamilyCode.fingerprint(FamilyCode.key(a)), FamilyCode.fingerprint(FamilyCode.key(a)))
        XCTAssertNotEqual(FamilyCode.fingerprint(FamilyCode.key(a)), FamilyCode.fingerprint(FamilyCode.key(b)))
        XCTAssertEqual(FamilyCode.tag("m", FamilyCode.key(a)), FamilyCode.tag("m", FamilyCode.key(a)))
        XCTAssertNotEqual(FamilyCode.tag("m", FamilyCode.key(a)), FamilyCode.tag("m", FamilyCode.key(b)))
        XCTAssertNotEqual(FamilyCode.tag("m", FamilyCode.key(a)), FamilyCode.tag("n", FamilyCode.key(a)))
    }
    #endif
}
