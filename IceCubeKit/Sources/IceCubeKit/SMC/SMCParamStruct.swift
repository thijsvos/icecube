// SMCParamStruct.swift — the exact 80-byte wire struct AppleSMC expects, plus its selector/command constants.

import Foundation

/// The IOKit selector for every SMC call (`kSMCHandleYPCEvent`).
public let kSMCSelectorHandleYPCEvent: UInt32 = 2

/// The SMC commands Ice Cube uses, passed in `SMCParamStruct.data8`.
///
/// Write (6) is listed for completeness but has **no caller in IceCubeKit** —
/// the write path is added in the helper daemon in Phase 3; the app process
/// deliberately contains no code that can write.
public enum SMCCommand {
    public static let readBytes: UInt8 = 5
    public static let writeBytes: UInt8 = 6
    public static let readKeyByIndex: UInt8 = 8
    public static let readKeyInfo: UInt8 = 9
}

/// 32 raw data bytes, as a fixed-size tuple (Swift's representation of a C
/// `uint8_t[32]`).
public typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// SMC firmware version block (6 bytes on the wire).
public struct SMCVersion: Sendable {
    public var major: UInt8 = 0
    public var minor: UInt8 = 0
    public var build: UInt8 = 0
    public var reserved: UInt8 = 0
    public var release: UInt16 = 0
    public init() {}
}

/// Power-limit block (16 bytes). Unused by Ice Cube, but part of the wire layout.
public struct SMCPLimitData: Sendable {
    public var version: UInt16 = 0
    public var length: UInt16 = 0
    public var cpuPLimit: UInt32 = 0
    public var gpuPLimit: UInt32 = 0
    public var memPLimit: UInt32 = 0
    public init() {}
}

/// Key metadata block: size in bytes, 4-char type code, attribute bits.
public struct SMCKeyInfoData: Sendable {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0
    public init() {}
}

/// The parameter struct passed to `IOConnectCallStructMethod` for every SMC
/// call. AppleSMC validates the input size, so the layout must match the
/// kernel's C struct **byte for byte**: 80 bytes, with `result` at offset 40,
/// `data32` at 44 and `bytes` at 48 (`SMCParamStructTests` asserts this — if
/// it ever fails, a Swift layout change broke the ABI and nothing will work).
///
/// The explicit `padding` field reproduces C's tail padding after the 9-byte
/// `keyInfo` (C pads the nested struct to 12; Swift packs to 9, so without it
/// every following field would sit 3 bytes early). Layout per beltex/SMCKit
/// (MIT) — see docs/CREDITS.md.
public struct SMCParamStruct: Sendable {
    public var key: UInt32 = 0
    public var vers = SMCVersion()
    public var pLimitData = SMCPLimitData()
    public var keyInfo = SMCKeyInfoData()
    public var padding: UInt16 = 0
    /// The firmware's verdict — **checked on every call**: IOKit can return
    /// `kIOReturnSuccess` while the firmware rejected the operation.
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    /// The command byte (`SMCCommand`).
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCBytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
    public init() {}

    /// The first `count` data bytes as an array (reading a value out of a
    /// reply).
    public func dataBytes(_ count: Int) -> [UInt8] {
        withUnsafeBytes(of: bytes) { raw in
            Array(raw.prefix(max(0, min(count, 32))))
        }
    }
}
