import XCTest
@testable import WoodruffKit

final class CoreTests: XCTestCase {
    func testParsesQRCodeLink() {
        let c = TVConnection.parse("http://192.168.68.91:8090/?k=AbCdEf123")
        XCTAssertEqual(c?.base.absoluteString, "http://192.168.68.91:8090")
        XCTAssertEqual(c?.key, "AbCdEf123")
    }

    func testParsesBareAddressWithKey() {
        let c = TVConnection.parse("10.0.0.5", key: "kk")
        XCTAssertEqual(c?.base.absoluteString, "http://10.0.0.5:8090")
        XCTAssertNil(TVConnection.parse("10.0.0.5"))
    }

    func testURLCarriesKey() {
        let c = TVConnection(base: URL(string: "http://tv:8080")!, key: "abc")
        XCTAssertEqual(c.url("/api/memories/thumb", ["name": "a b.jpg"]).absoluteString, "http://tv:8080/api/memories/thumb?name=a%20b.jpg&k=abc")
        XCTAssertEqual(c.pairingLink.absoluteString, "http://tv:8080/?k=abc")
    }

    func testVersions() {
        XCTAssertLessThan(WoodruffVersion("2.0.99")!, WoodruffVersion("v2.0.100")!)
        XCTAssertLessThan(WoodruffVersion("2.0.5")!, WoodruffVersion("webos-6")!)
        XCTAssertEqual(WoodruffVersion("webos-312")?.build, 312)
        XCTAssertNil(WoodruffVersion("abc"))
        XCTAssertFalse(WoodruffVersion("2.0.7")! < WoodruffVersion("2.0.7")!)
    }

    func testWakeOnLANPacket() {
        let p = WakeOnLAN.packet(mac: "a8:23:fe:01:02:03")
        XCTAssertEqual(p?.count, 102)
        XCTAssertEqual(p?.prefix(6), Data(repeating: 0xFF, count: 6))
        XCTAssertNil(WakeOnLAN.packet(mac: "nope"))
    }

    func testErrorBodies() {
        XCTAssertEqual(TVError.from(status: 400, data: Data("Unknown TV".utf8)).errorDescription, "Unknown TV")
        XCTAssertEqual(TVError.from(status: 409, data: Data(#"{"message":"LG TVs don't"}"#.utf8)).errorDescription, "LG TVs don't")
        XCTAssertTrue(TVError.from(status: 401, data: Data()).isRefused)
    }

    func testJSONValue() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,"x",true,null],"b":{"c":2.5}}"#.utf8))
        XCTAssertEqual(v["a"]?.array.count, 4)
        XCTAssertEqual(v["b"]?["c"]?.double, 2.5)
        XCTAssertEqual(v["a"]?.array[0].int, 1)
    }

    func testNumbersTooLargeForIntDontCrash() {
        XCTAssertEqual(JSONValue.number(42).string, "42")
        XCTAssertEqual(JSONValue.number(2.5).string, "2.5")
        XCTAssertEqual(JSONValue.number(1e20).string, String(1e20))
        XCTAssertEqual(JSONValue.number(-7.9).int, -7)
        XCTAssertEqual(JSONValue.string("12").int, 12)
        XCTAssertNil(JSONValue.number(1e20).int)
        XCTAssertNil(JSONValue.string("nan").int)
        XCTAssertNil(JSONValue.string("inf").int)
    }

    func testMemoryVersionNeverCrashes() {
        func item(_ v: Double?) -> MemoryItem { MemoryItem(path: "/a.jpg", name: "a.jpg", video: false, taken: nil, size: nil, v: v) }
        XCTAssertEqual(item(3).version, "3")
        XCTAssertEqual(item(nil).version, "0")
        XCTAssertEqual(item(1e30).version, "0")
    }

    func testURLWithoutLeadingSlash() {
        let c = TVConnection(base: URL(string: "http://tv:8090")!, key: "abc")
        XCTAssertEqual(c.url("api/status", withKey: false).absoluteString, "http://tv:8090/api/status")
        XCTAssertEqual(c.url("/api/status", withKey: false).absoluteString, "http://tv:8090/api/status")
    }

    func testLGManifestDecodes() {
        XCTAssertEqual(LGRemote.manifest["manifestVersion"]?.int, 1)
        XCTAssertFalse(LGRemote.manifest["signatures"]?.array.isEmpty ?? true)
    }
}
