// SMCKeyCodec.swift — pure byte-level codec for SMC key names and data types; no IOKit, testable anywhere.

import Foundation

/// The SMC data types Zephyr understands, named **exactly** as the SMC reports
/// them in key-info responses — so `SMCDataType(rawValue: "flt ")` maps
/// firmware metadata straight to a case (note the trailing spaces in some names).
public enum SMCDataType: String, Sendable, CaseIterable, Equatable {
    /// Little-endian IEEE-754 float32, 4 bytes — the Apple Silicon fan format
    /// (`F{i}Ac`, `F{i}Tg`, `F{i}Mn`, `F{i}Mx`) and most modern sensors.
    case float = "flt "
    /// Big-endian 14.2 fixed point, 2 bytes: value = `((b0 << 8) | b1) / 4`,
    /// i.e. RPM stored ×4, resolution 0.25, max 16383.75. The Intel-era fan
    /// format — kept for reads so the community can port an Intel path later.
    case fpe2
    /// Unsigned 8-bit integer, 1 byte (e.g. `FNum`, `F{i}Md`, `Ftst`).
    case uint8 = "ui8 "
    /// Big-endian unsigned 16-bit integer, 2 bytes.
    case uint16 = "ui16"
    /// Big-endian unsigned 32-bit integer, 4 bytes (e.g. `#KEY`).
    case uint32 = "ui32"
    /// One-byte boolean: 0 = false, anything else = true. Read-only for us.
    case flag
    /// Fan-descriptor struct, 16 bytes (`F{i}ID`): 4 header bytes, then a
    /// 12-byte ASCII name field. We decode only the name — see `decodeString`.
    case fanDescriptor = "{fds"

    /// The 4-character type code exactly as the SMC reports it (e.g. `"flt "`).
    public var name: String {
        rawValue
    }

    /// The exact number of bytes a value of this type occupies on the wire.
    public var byteCount: Int {
        switch self {
        case .float: 4
        case .fpe2: 2
        case .uint8: 1
        case .uint16: 2
        case .uint32: 4
        case .flag: 1
        case .fanDescriptor: 16
        }
    }
}

/// Pure functions translating between SMC wire bytes and Swift values.
///
/// Everything here is exact and policy-free: the codec never clamps. Clamping a
/// requested RPM to a fan's safe `[minRPM, maxRPM]` range is the *daemon's* job
/// before it ever calls `encode`; a value the wire type itself cannot represent
/// throws `ZephyrError.smcEncodingFailed` instead of being silently adjusted.
///
/// API shape: separate typed functions (`decodeDouble` / `decodeBool` /
/// `decodeString`) rather than a wrapped `SMCValue` enum. Call sites always
/// know statically which Swift type a key yields (an RPM key is a number, a
/// fan-descriptor is a name), so a wrapper enum would only add a runtime
/// unwrap-and-hope step at every call.
public enum SMCKeyCodec {
    // MARK: - Four-character key codes

    /// Packs a 4-character ASCII key like `"F0Ac"` into the big-endian
    /// `UInt32` that IOKit expects: `'F' << 24 | '0' << 16 | 'A' << 8 | 'c'`.
    ///
    /// - Throws: `ZephyrError.smcDecodingFailed` unless `key` is exactly four
    ///   printable-ASCII characters (0x20…0x7E; `"#KEY"` and `"FS! "` are
    ///   valid). Key-name failures use the *decoding* case in both directions
    ///   because it carries the offending key string and its bytes.
    public static func keyCode(for key: String) throws -> UInt32 {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) }) else {
            throw ZephyrError.smcDecodingFailed(key: key, type: "FourCharCode", bytes: Array(key.utf8))
        }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1.value) }
    }

    /// Unpacks a big-endian `UInt32` key code back into its 4-character string
    /// (used when enumerating keys by index via `#KEY`).
    ///
    /// - Throws: `ZephyrError.smcDecodingFailed` if any byte falls outside
    ///   printable ASCII — a garbage code is more useful as an error than as
    ///   mojibake in a sensor list.
    public static func keyString(from code: UInt32) throws -> String {
        let bytes: [UInt8] = [
            UInt8(code >> 24), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        guard bytes.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else {
            let hex = String(format: "0x%08X", code)
            throw ZephyrError.smcDecodingFailed(key: hex, type: "FourCharCode", bytes: bytes)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Decoding

    /// Decodes `bytes` as a numeric SMC type: `flt`, `fpe2`, `ui8`, `ui16`,
    /// or `ui32`.
    ///
    /// - Parameter key: the SMC key the bytes came from — only used to make
    ///   errors self-describing, so it may be omitted in tests.
    /// - Throws: `ZephyrError.smcDecodingFailed` (carrying the offending
    ///   bytes) when the byte count is wrong for the type, when the type is
    ///   not numeric (`flag` → `decodeBool`, `{fds` → `decodeString`), or when
    ///   a `flt` value is NaN or ±infinity — a non-finite RPM or temperature
    ///   is always garbage, never a real reading, so it is rejected here
    ///   rather than left to poison a curve or a UI label downstream.
    public static func decodeDouble(
        _ bytes: [UInt8], as type: SMCDataType, forKey key: String = ""
    ) throws -> Double {
        try checkCount(bytes, type: type, key: key)
        switch type {
        case .float:
            // Little-endian: lowest-order byte first.
            let pattern = (UInt32(bytes[3]) << 24) | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[1]) << 8) | UInt32(bytes[0])
            let value = Double(Float(bitPattern: pattern))
            guard value.isFinite else {
                throw ZephyrError.smcDecodingFailed(key: key, type: type.name, bytes: bytes)
            }
            return value
        case .fpe2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
        case .uint8:
            return Double(bytes[0])
        case .uint16:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case .uint32:
            let raw = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return Double(raw)
        case .flag, .fanDescriptor:
            throw ZephyrError.smcDecodingFailed(key: key, type: type.name, bytes: bytes)
        }
    }

    /// Decodes a 1-byte `flag` value: 0 is `false`, anything else is `true`.
    ///
    /// - Throws: `ZephyrError.smcDecodingFailed` if `bytes` is not exactly 1 byte.
    public static func decodeBool(_ bytes: [UInt8], forKey key: String = "") throws -> Bool {
        try checkCount(bytes, type: .flag, key: key)
        return bytes[0] != 0
    }

    /// Decodes the fan name out of a 16-byte `{fds` fan-descriptor struct
    /// (`F{i}ID`): bytes 4…15 are a 12-byte ASCII name field, NUL- or
    /// space-padded (e.g. "Left", "Right", "Exhaust"). Kept deliberately
    /// minimal — the name is the only field Zephyr needs.
    ///
    /// - Returns: the name with padding trimmed; may be empty if the field is
    ///   all padding.
    /// - Throws: `ZephyrError.smcDecodingFailed` if `bytes` is not exactly 16
    ///   bytes, or the name field contains non-printable/non-ASCII garbage.
    public static func decodeString(_ bytes: [UInt8], forKey key: String = "") throws -> String {
        try checkCount(bytes, type: .fanDescriptor, key: key)
        let nameField = bytes[4 ..< 16].prefix { $0 != 0 } // stop at NUL padding
        guard nameField.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else {
            throw ZephyrError.smcDecodingFailed(key: key, type: SMCDataType.fanDescriptor.name, bytes: bytes)
        }
        return String(decoding: nameField, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Encoding

    /// Encodes `value` into wire bytes for a writable numeric type: `flt`,
    /// `fpe2`, `ui8`, `ui16`, or `ui32`.
    ///
    /// The codec is exact, not a guard rail — **no clamping** happens here
    /// (the daemon clamps to fan limits *before* encoding). Two deliberate
    /// precision rules, chosen per type:
    /// - `fpe2` rounds to its 0.25 resolution (it is a fixed-point *real*
    ///   format, so nearest-step rounding is the honest conversion) but never
    ///   rounds past its 0…16383.75 range — out of range still throws.
    /// - `ui8`/`ui16`/`ui32` require integral values: a fractional value sent
    ///   to an integer key is a caller bug, not something to round away.
    ///
    /// - Throws: `ZephyrError.smcEncodingFailed` for NaN/±infinity, values
    ///   outside the type's representable range (including `flt` overflow of
    ///   float32), fractional values for integer types, and the non-writable
    ///   types (`flag`, `{fds`).
    public static func encode(_ value: Double, as type: SMCDataType) throws -> [UInt8] {
        guard value.isFinite else {
            throw ZephyrError.smcEncodingFailed(type: type.name, value: value)
        }
        switch type {
        case .float:
            let float32 = Float(value)
            guard float32.isFinite else { // magnitude too large for float32
                throw ZephyrError.smcEncodingFailed(type: type.name, value: value)
            }
            let p = float32.bitPattern
            return [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)]
        case .fpe2:
            guard (0.0 ... 16383.75).contains(value) else {
                throw ZephyrError.smcEncodingFailed(type: type.name, value: value)
            }
            let raw = UInt16((value * 4).rounded()) // quarter-RPM steps
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case .uint8:
            try checkIntegral(value, max: 255, type: type)
            return [UInt8(value)]
        case .uint16:
            try checkIntegral(value, max: 65535, type: type)
            let raw = UInt16(value)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case .uint32:
            try checkIntegral(value, max: 4_294_967_295, type: type)
            let raw = UInt32(value)
            return [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        case .flag, .fanDescriptor:
            throw ZephyrError.smcEncodingFailed(type: type.name, value: value)
        }
    }

    // MARK: - Shared validation

    /// Throws `smcDecodingFailed` (with the offending bytes) unless `bytes`
    /// has exactly the byte count `type` requires.
    private static func checkCount(_ bytes: [UInt8], type: SMCDataType, key: String) throws {
        guard bytes.count == type.byteCount else {
            throw ZephyrError.smcDecodingFailed(key: key, type: type.name, bytes: bytes)
        }
    }

    /// Throws `smcEncodingFailed` unless `value` is a whole number in `0...max`.
    private static func checkIntegral(_ value: Double, max: Double, type: SMCDataType) throws {
        guard value >= 0, value <= max, value.truncatingRemainder(dividingBy: 1) == 0 else {
            throw ZephyrError.smcEncodingFailed(type: type.name, value: value)
        }
    }
}
