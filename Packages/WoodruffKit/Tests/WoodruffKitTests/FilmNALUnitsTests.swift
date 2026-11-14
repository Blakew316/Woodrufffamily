import XCTest
@testable import WoodruffKit

/// A picture marked "hev1" can repeat its parameter sets inside its frames; handed over as "hvc1"/"dvh1", the copies
/// the sample description already gives are taken out of the frames, and nothing else is.
final class FilmNALUnitsTests: XCTestCase {
    private func unit(_ type: UInt8, _ body: [UInt8]) -> [UInt8] { [type << 1, 1] + body }

    private func frame(_ units: [[UInt8]], size: Int = 4) -> Data {
        var d = Data()
        for u in units {
            var length = [UInt8](repeating: 0, count: size)
            var n = u.count
            for i in stride(from: size - 1, through: 0, by: -1) { length[i] = UInt8(n & 0xFF); n >>= 8 }
            d.append(contentsOf: length + u)
        }
        return d
    }

    private lazy var vps = unit(32, [0xAA, 0x01])
    private lazy var sps = unit(33, [0xBB, 0x02, 0x03])
    private lazy var pps = unit(34, [0xCC])
    private lazy var sei = unit(39, [0x05])
    private lazy var slice = unit(19, Array(repeating: 0x42, count: 50))
    private lazy var rpu = unit(62, [0x07, 0x08])

    /// An `hvcC` with four-byte lengths and the three parameter sets.
    private func hvcC() -> Data {
        var h = [UInt8](repeating: 0, count: 23)
        h[0] = 1
        h[21] = 0xF0 | 3
        h[22] = 3
        for (type, u) in [(UInt8(32), vps), (33, sps), (34, pps)] {
            h += [0x80 | type, 0, 1, UInt8(u.count >> 8), UInt8(u.count & 0xFF)] + u
        }
        return Data(h)
    }

    func testTheSampleDescriptionsSetsAreRead() throws {
        let known = try XCTUnwrap(FilmNALUnits.parameterSets(hvcC: hvcC()))
        XCTAssertEqual(known.lengthSize, 4)
        XCTAssertEqual(known.sets, [Data(vps), Data(sps), Data(pps)])
        XCTAssertNil(FilmNALUnits.parameterSets(hvcC: Data([0, 1, 2])))
    }

    func testAKeyframeLosesOnlyTheRepeatedSets() throws {
        let known = try XCTUnwrap(FilmNALUnits.parameterSets(hvcC: hvcC()))
        let key = frame([vps, sps, pps, sei, slice, rpu])
        XCTAssertEqual(FilmNALUnits.withoutKnownSets(key, lengthSize: 4, sets: known.sets), frame([sei, slice, rpu]))
        // Read from inside a bigger buffer, as the player's runs are.
        let run = Data([9, 9, 9]) + key + Data([7])
        XCTAssertEqual(FilmNALUnits.withoutKnownSets(run[3..<(3 + key.count)], lengthSize: 4, sets: known.sets), frame([sei, slice, rpu]))
    }

    func testOtherFramesAndChangedSetsAreLeftAlone() throws {
        let known = try XCTUnwrap(FilmNALUnits.parameterSets(hvcC: hvcC()))
        // No sets in it: used as it is.
        XCTAssertNil(FilmNALUnits.withoutKnownSets(frame([slice, rpu]), lengthSize: 4, sets: known.sets))
        // A sequence parameter set that differs from the description's stays: the decoder needs it.
        let changed = unit(33, [0xBB, 0x02, 0x04])
        XCTAssertEqual(FilmNALUnits.withoutKnownSets(frame([vps, changed, pps, slice]), lengthSize: 4, sets: known.sets), frame([changed, slice]))
        // Lengths that don't add up, or nothing left but the sets: left alone.
        var broken = frame([vps, slice])
        broken[3] = 0xFF
        XCTAssertNil(FilmNALUnits.withoutKnownSets(broken, lengthSize: 4, sets: known.sets))
        XCTAssertNil(FilmNALUnits.withoutKnownSets(frame([vps, sps, pps]), lengthSize: 4, sets: known.sets))
        // Two-byte lengths.
        XCTAssertEqual(FilmNALUnits.withoutKnownSets(frame([sps, slice], size: 2), lengthSize: 2, sets: known.sets), frame([slice], size: 2))
    }

    /// "End of sequence" and "end of bitstream" make Apple's decoder start afresh at the next keyframe: they go too,
    /// with or without parameter sets to take out.
    func testEndOfSequenceMarkersGo() throws {
        let known = try XCTUnwrap(FilmNALUnits.parameterSets(hvcC: hvcC()))
        let eos = unit(36, []), eob = unit(37, [])
        XCTAssertEqual(FilmNALUnits.withoutKnownSets(frame([slice, rpu, eos]), lengthSize: 4, sets: known.sets), frame([slice, rpu]))
        XCTAssertEqual(FilmNALUnits.withoutKnownSets(frame([slice, eob]), lengthSize: 4, sets: []), frame([slice]))
        XCTAssertNil(FilmNALUnits.withoutKnownSets(frame([slice, rpu]), lengthSize: 4, sets: []))
    }

    func testTheKindsOfAFramesPieces() {
        XCTAssertEqual(FilmNALUnits.kinds(frame([vps, sps, pps, sei, slice, rpu]), lengthSize: 4), [32, 33, 34, 39, 19, 62])
        var broken = frame([vps, slice])
        broken[3] = 0xFF
        XCTAssertNil(FilmNALUnits.kinds(broken, lengthSize: 4))
    }
}
