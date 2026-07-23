// SMCKeyCodecTests.swift — exhaustive byte-level codec tests; this codec is historically where fan apps break.

import IceCubeKit
import XCTest

final class SMCKeyCodecTests: XCTestCase {
    // MARK: - Four-character key codes

    func testKeyCodeKnownValues() throws {
        // Big-endian packing, e.g. 'F'=0x46 '0'=0x30 'A'=0x41 'c'=0x63.
        XCTAssertEqual(try SMCKeyCodec.keyCode(for: "F0Ac"), 0x4630_4163)
        XCTAssertEqual(try SMCKeyCodec.keyCode(for: "#KEY"), 0x234B_4559)
        XCTAssertEqual(try SMCKeyCodec.keyCode(for: "FS! "), 0x4653_2120)
        XCTAssertEqual(try SMCKeyCodec.keyCode(for: "Tp01"), 0x5470_3031)
    }

    func testKeyCodeRoundtrip() throws {
        for key in ["F0Ac", "#KEY", "FS! ", "Tp01", "FNum", "F0Mx", "    ", "~~~~"] {
            XCTAssertEqual(try SMCKeyCodec.keyString(from: SMCKeyCodec.keyCode(for: key)), key)
        }
    }

    func testKeyCodeRejectsBadKeys() {
        // Wrong length, non-ASCII, and control characters must all throw.
        for bad in ["", "F0A", "F0Acx", "F0Aé", "F0A\n", "🔥🔥🔥🔥"] {
            try assertThrowsDecodingFailed(SMCKeyCodec.keyCode(for: bad), "key '\(bad)'")
        }
    }

    func testKeyStringRejectsNonPrintableCode() {
        try assertThrowsDecodingFailed(SMCKeyCodec.keyString(from: 0x0046_3041)) // NUL byte
        try assertThrowsDecodingFailed(SMCKeyCodec.keyString(from: 0xFF46_3041)) // non-ASCII byte
    }

    // MARK: - fpe2 (big-endian 14.2 fixed point)

    func testFpe2DecodeFixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x2E, 0xE0], as: .fpe2), 3000.0) // real 3000 RPM read
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00, 0x04], as: .fpe2), 1.0)
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0xFF, 0xFF], as: .fpe2), 16383.75) // type max
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00, 0x00], as: .fpe2), 0.0)
    }

    func testFpe2EncodeFixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.encode(3000.0, as: .fpe2), [0x2E, 0xE0])
        XCTAssertEqual(try SMCKeyCodec.encode(1.0, as: .fpe2), [0x00, 0x04])
        XCTAssertEqual(try SMCKeyCodec.encode(16383.75, as: .fpe2), [0xFF, 0xFF])
        XCTAssertEqual(try SMCKeyCodec.encode(0.0, as: .fpe2), [0x00, 0x00])
    }

    func testFpe2RoundsToQuarterSteps() throws {
        // Sub-0.25 precision rounds to the nearest representable step.
        XCTAssertEqual(try SMCKeyCodec.encode(1200.1, as: .fpe2), try SMCKeyCodec.encode(1200.0, as: .fpe2))
        let rounded = try SMCKeyCodec.decodeDouble(SMCKeyCodec.encode(1200.13, as: .fpe2), as: .fpe2)
        XCTAssertEqual(rounded, 1200.25)
    }

    func testFpe2EncodeRejectsOutOfRange() {
        // Rounding never rescues an out-of-range value (16383.76 must not become 0xFFFF).
        for bad in [-0.25, -1.0, 16383.76, 16384.0, 100_000.0] {
            try assertThrowsEncodingFailed(SMCKeyCodec.encode(bad, as: .fpe2), "value \(bad)")
        }
    }

    func testFpe2ExhaustiveRoundtrip() throws {
        // Every one of the 65536 possible wire patterns, both directions.
        for raw in 0 ... 65535 {
            let bytes: [UInt8] = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
            let value = try SMCKeyCodec.decodeDouble(bytes, as: .fpe2)
            let encoded = try SMCKeyCodec.encode(value, as: .fpe2)
            if value != Double(raw) / 4.0 || encoded != bytes {
                return XCTFail("fpe2 roundtrip failed at raw pattern \(raw)")
            }
        }
    }

    // MARK: - flt (little-endian IEEE-754 float32)

    func testFloatDecodeFixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00, 0x80, 0xBB, 0x44], as: .float), 1500.0)
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00, 0x00, 0x00, 0x00], as: .float), 0.0)
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00, 0x70, 0xC9, 0x45], as: .float), 6446.0) // M2 Pro max fan
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00, 0x00, 0x80, 0xBF], as: .float), -1.0)
    }

    func testFloatEncodeFixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.encode(1500.0, as: .float), [0x00, 0x80, 0xBB, 0x44])
        XCTAssertEqual(try SMCKeyCodec.encode(0.0, as: .float), [0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(try SMCKeyCodec.encode(6446.0, as: .float), [0x00, 0x70, 0xC9, 0x45])
        XCTAssertEqual(try SMCKeyCodec.encode(-1.0, as: .float), [0x00, 0x00, 0x80, 0xBF])
    }

    func testFloatDecodeRejectsNonFinite() {
        // Documented decision: NaN/±inf never occur as a real RPM or temperature — always throw.
        let garbage: [[UInt8]] = [
            [0x00, 0x00, 0xC0, 0x7F], // quiet NaN
            [0x00, 0x00, 0x80, 0x7F], // +infinity
            [0x00, 0x00, 0x80, 0xFF], // -infinity
        ]
        for bytes in garbage {
            try assertThrowsDecodingFailed(SMCKeyCodec.decodeDouble(bytes, as: .float), "bytes \(bytes)")
        }
    }

    func testFloatEncodeRejectsNonFinite() {
        // NaN, infinities, and finite Doubles too large for float32.
        for bad in [Double.nan, .infinity, -.infinity, 1e39, -1e39] {
            try assertThrowsEncodingFailed(SMCKeyCodec.encode(bad, as: .float), "value \(bad)")
        }
    }

    func testFloatSteppedRoundtrip() throws {
        // ~4000 stepped values across the plausible fan/temp range, incl. negatives.
        // Step 3.25 keeps every value exactly representable in float32.
        var count = 0
        var value = -6446.0
        while value <= 6446.0 {
            let bytes = try SMCKeyCodec.encode(value, as: .float)
            if try SMCKeyCodec.decodeDouble(bytes, as: .float) != value {
                return XCTFail("flt roundtrip failed at \(value)")
            }
            count += 1
            value += 3.25
        }
        XCTAssertGreaterThan(count, 3900)
    }

    // MARK: - ui8 / ui16 / ui32 (big-endian unsigned integers)

    func testUInt8Fixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x00], as: .uint8), 0)
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0xFF], as: .uint8), 255)
        XCTAssertEqual(try SMCKeyCodec.encode(2.0, as: .uint8), [0x02]) // FNum on an M2 Pro
    }

    func testUInt16BigEndianFixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x12, 0x34], as: .uint16), 4660)
        XCTAssertEqual(try SMCKeyCodec.encode(256.0, as: .uint16), [0x01, 0x00]) // catches LE/BE swaps
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0xFF, 0xFF], as: .uint16), 65535)
        XCTAssertEqual(try SMCKeyCodec.encode(0.0, as: .uint16), [0x00, 0x00])
    }

    func testUInt32BigEndianFixtures() throws {
        XCTAssertEqual(try SMCKeyCodec.decodeDouble([0x01, 0x02, 0x03, 0x04], as: .uint32), 16_909_060)
        XCTAssertEqual(try SMCKeyCodec.encode(1.0, as: .uint32), [0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(try SMCKeyCodec.encode(4_294_967_295.0, as: .uint32), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testUnsignedEncodeRejectsOutOfRangeAndFractions() {
        let bad: [(SMCDataType, Double)] = [
            (.uint8, 256), (.uint8, -1), (.uint8, 1.5),
            (.uint16, 65536), (.uint16, 0.25),
            (.uint32, 4_294_967_296), (.uint32, -0.5),
        ]
        for (type, value) in bad {
            try assertThrowsEncodingFailed(SMCKeyCodec.encode(value, as: type), "\(type.name) \(value)")
        }
    }

    func testUInt8ExhaustiveRoundtrip() throws {
        for raw in 0 ... 255 {
            let value = Double(raw)
            if try SMCKeyCodec.decodeDouble(SMCKeyCodec.encode(value, as: .uint8), as: .uint8) != value {
                return XCTFail("ui8 roundtrip failed at \(raw)")
            }
        }
    }

    func testUInt16ExhaustiveRoundtrip() throws {
        for raw in 0 ... 65535 {
            let value = Double(raw)
            if try SMCKeyCodec.decodeDouble(SMCKeyCodec.encode(value, as: .uint16), as: .uint16) != value {
                return XCTFail("ui16 roundtrip failed at \(raw)")
            }
        }
    }

    func testUInt32SteppedRoundtrip() throws {
        // ~65k stepped values over the full range; 65537 stride hits varied byte patterns.
        var raw: UInt64 = 0
        while raw <= 4_294_967_295 {
            let value = Double(raw)
            if try SMCKeyCodec.decodeDouble(SMCKeyCodec.encode(value, as: .uint32), as: .uint32) != value {
                return XCTFail("ui32 roundtrip failed at \(raw)")
            }
            raw += 65537
        }
        // Explicit max boundary (the stride overshoots it).
        let max = 4_294_967_295.0
        XCTAssertEqual(try SMCKeyCodec.decodeDouble(SMCKeyCodec.encode(max, as: .uint32), as: .uint32), max)
    }

    // MARK: - flag

    func testFlagDecode() throws {
        XCTAssertFalse(try SMCKeyCodec.decodeBool([0x00]))
        XCTAssertTrue(try SMCKeyCodec.decodeBool([0x01]))
        XCTAssertTrue(try SMCKeyCodec.decodeBool([0x02])) // any nonzero byte is true
    }

    func testFlagIsNeitherNumericNorWritable() {
        try assertThrowsDecodingFailed(SMCKeyCodec.decodeDouble([0x01], as: .flag))
        try assertThrowsEncodingFailed(SMCKeyCodec.encode(1.0, as: .flag))
    }

    // MARK: - {fds fan-descriptor name

    func testFanDescriptorNameExtraction() throws {
        // 4 header bytes, then the 12-byte name field, NUL-padded — as F0ID reports.
        let left: [UInt8] = [0x00, 0x00, 0x00, 0x01] + Array("Left".utf8) + [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(try SMCKeyCodec.decodeString(left), "Left")

        // Space padding inside the field is trimmed too.
        let exhaust: [UInt8] = [0x00, 0x00, 0x00, 0x01] + Array("Exhaust ".utf8) + [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(try SMCKeyCodec.decodeString(exhaust), "Exhaust")

        // All-padding name field decodes to an empty string, not an error.
        let empty: [UInt8] = [0x00, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 12)
        XCTAssertEqual(try SMCKeyCodec.decodeString(empty), "")
    }

    func testFanDescriptorRejectsWrongLengthAndGarbage() {
        try assertThrowsDecodingFailed(SMCKeyCodec.decodeString([UInt8](repeating: 0, count: 15)))
        try assertThrowsDecodingFailed(SMCKeyCodec.decodeString([UInt8](repeating: 0, count: 17)))
        // Non-printable bytes before the NUL terminator are garbage, not a name.
        let garbage: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0xC3, 0x28, 0x07] + [UInt8](repeating: 0, count: 9)
        try assertThrowsDecodingFailed(SMCKeyCodec.decodeString(garbage))
        // {fds is not numeric and never writable.
        try assertThrowsDecodingFailed(SMCKeyCodec.decodeDouble([UInt8](repeating: 0, count: 16), as: .fanDescriptor))
        try assertThrowsEncodingFailed(SMCKeyCodec.encode(1.0, as: .fanDescriptor))
    }

    // MARK: - Error payloads and byte-count validation

    func testDecodeErrorCarriesKeyTypeAndOffendingBytes() {
        XCTAssertThrowsError(try SMCKeyCodec.decodeDouble([0x2E], as: .fpe2, forKey: "F0Ac")) { error in
            guard case let IceCubeError.smcDecodingFailed(key, type, bytes) = error else {
                return XCTFail("expected smcDecodingFailed, got \(error)")
            }
            XCTAssertEqual(key, "F0Ac")
            XCTAssertEqual(type, "fpe2")
            XCTAssertEqual(bytes, [0x2E])
        }
    }

    func testEncodeErrorCarriesTypeAndValue() {
        XCTAssertThrowsError(try SMCKeyCodec.encode(16384.0, as: .fpe2)) { error in
            guard case let IceCubeError.smcEncodingFailed(type, value) = error else {
                return XCTFail("expected smcEncodingFailed, got \(error)")
            }
            XCTAssertEqual(type, "fpe2")
            XCTAssertEqual(value, 16384.0)
        }
    }

    func testDecodeRejectsWrongByteCountForEveryType() {
        for type in SMCDataType.allCases {
            for badCount in [0, type.byteCount - 1, type.byteCount + 1] where badCount >= 0 {
                let bytes = [UInt8](repeating: 0, count: badCount)
                switch type {
                case .flag:
                    try assertThrowsDecodingFailed(SMCKeyCodec.decodeBool(bytes), "\(type.name) count \(badCount)")
                case .fanDescriptor:
                    try assertThrowsDecodingFailed(SMCKeyCodec.decodeString(bytes), "\(type.name) count \(badCount)")
                default:
                    try assertThrowsDecodingFailed(
                        SMCKeyCodec.decodeDouble(bytes, as: type),
                        "\(type.name) count \(badCount)"
                    )
                }
            }
        }
    }

    // MARK: - SMCDataType metadata

    func testDataTypeNamesMatchSMCReporting() {
        XCTAssertEqual(SMCDataType(rawValue: "flt "), .float)
        XCTAssertEqual(SMCDataType(rawValue: "fpe2"), .fpe2)
        XCTAssertEqual(SMCDataType(rawValue: "ui8 "), .uint8)
        XCTAssertEqual(SMCDataType(rawValue: "ui16"), .uint16)
        XCTAssertEqual(SMCDataType(rawValue: "ui32"), .uint32)
        XCTAssertEqual(SMCDataType(rawValue: "flag"), .flag)
        XCTAssertEqual(SMCDataType(rawValue: "{fds"), .fanDescriptor)
        XCTAssertNil(SMCDataType(rawValue: "sp78")) // not handled in v1
        XCTAssertNil(SMCDataType(rawValue: "flt")) // trailing space is part of the name
    }

    func testDataTypeByteCounts() {
        XCTAssertEqual(SMCDataType.float.byteCount, 4)
        XCTAssertEqual(SMCDataType.fpe2.byteCount, 2)
        XCTAssertEqual(SMCDataType.uint8.byteCount, 1)
        XCTAssertEqual(SMCDataType.uint16.byteCount, 2)
        XCTAssertEqual(SMCDataType.uint32.byteCount, 4)
        XCTAssertEqual(SMCDataType.flag.byteCount, 1)
        XCTAssertEqual(SMCDataType.fanDescriptor.byteCount, 16)
    }

    // MARK: - Helpers

    /// Asserts the expression throws `IceCubeError.smcDecodingFailed`.
    private func assertThrowsDecodingFailed(
        _ expression: @autoclosure () throws -> some Any, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard case IceCubeError.smcDecodingFailed = error else {
                return XCTFail("expected smcDecodingFailed (\(message)), got \(error)", file: file, line: line)
            }
        }
    }

    /// Asserts the expression throws `IceCubeError.smcEncodingFailed`.
    private func assertThrowsEncodingFailed(
        _ expression: @autoclosure () throws -> some Any, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard case IceCubeError.smcEncodingFailed = error else {
                return XCTFail("expected smcEncodingFailed (\(message)), got \(error)", file: file, line: line)
            }
        }
    }
}
