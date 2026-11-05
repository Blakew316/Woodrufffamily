import XCTest
@testable import WoodruffKit

/// A Govee lamp also in Apple Home is one lamp: their names reduce to the same key.
final class SameLampTests: XCTestCase {
    func testGoveeAndAppleHomeNamesMatch() {
        XCTAssertEqual(SmartHome.sameLampKey("Blake's Govee Floor Lamp"), SmartHome.sameLampKey("Blake's Floor Lamp 2"))
        XCTAssertEqual(SmartHome.sameLampKey("Haley’s Govee Floor Lamp"), SmartHome.sameLampKey("Haley's Floor Lamp 2"))
        XCTAssertEqual(SmartHome.sameLampKey("Blake's Floor Lamp 2"), "blakes")
    }

    func testDifferentLampsDont() {
        XCTAssertNotEqual(SmartHome.sameLampKey("Blake's Floor Lamp 2"), SmartHome.sameLampKey("Haley's Floor Lamp 2"))
    }
}
