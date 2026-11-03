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
}
