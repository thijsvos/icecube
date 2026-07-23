// ZephyrError.swift — the typed error vocabulary for every SMC and helper failure path.

import Foundation

/// SMC firmware result codes, returned in `SMCParamStruct.result`.
///
/// IOKit can return `kIOReturnSuccess` while the firmware rejected the
/// operation — the result byte must be checked on **every** SMC call.
public enum SMCResult {
    /// Operation accepted by the firmware.
    public static let ok: UInt8 = 0x00
    /// Rejected — e.g. a fan-mode write while `thermalmonitord` holds mode 3
    /// on M3+ (needs the `Ftst` unlock sequence first).
    public static let badCommand: UInt8 = 0x82
    /// The key does not exist on this machine/generation.
    public static let keyNotFound: UInt8 = 0x84
}

/// `kIOReturnNotPrivileged` — fan *writes* fail with this without root.
/// (0xE00002C1; note the frequently mis-quoted 0xE00002C2 is `kIOReturnBadArgument`.)
public let kZephyrIONotPrivileged: Int32 = -536_870_207 // 0xE00002C1 as Int32

/// Every error Zephyr surfaces. Daemon code paths must never `fatalError`;
/// they throw one of these, log it, and revert to a safe state.
public enum ZephyrError: Error, Sendable, Equatable {
    /// Could not open a connection to the AppleSMC service.
    case smcConnectionFailed(kernReturn: Int32)
    /// An IOKit call itself failed (transport-level, not firmware-level).
    case smcCallFailed(key: String, kernReturn: Int32)
    /// The firmware answered but rejected the operation — see `SMCResult`.
    case smcFirmwareRejected(key: String, result: UInt8)
    /// The key does not exist on this machine (firmware result 0x84).
    case smcKeyNotFound(key: String)
    /// Write attempted without root (`kIOReturnNotPrivileged`) — only the
    /// helper daemon may write; the app should never see this.
    case smcNotPrivileged(key: String)
    /// The key's bytes could not be decoded as the expected type.
    case smcDecodingFailed(key: String, type: String, bytes: [UInt8])
    /// A value could not be encoded for writing (e.g. out of the type's range).
    case smcEncodingFailed(type: String, value: Double)
}

extension ZephyrError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .smcConnectionFailed(kr):
            "Could not connect to the SMC (IOKit error \(String(format: "0x%08X", UInt32(bitPattern: kr))))."
        case let .smcCallFailed(key, kr):
            "SMC call for key '\(key)' failed (IOKit error \(String(format: "0x%08X", UInt32(bitPattern: kr))))."
        case let .smcFirmwareRejected(key, result):
            "SMC firmware rejected the operation on key '\(key)' (result \(String(format: "0x%02X", result)))."
        case let .smcKeyNotFound(key):
            "SMC key '\(key)' does not exist on this machine."
        case let .smcNotPrivileged(key):
            "Writing SMC key '\(key)' requires root — only the helper daemon may write."
        case let .smcDecodingFailed(key, type, _):
            "Could not decode SMC key '\(key)' as type '\(type)'."
        case let .smcEncodingFailed(type, value):
            "Could not encode value \(value) as SMC type '\(type)'."
        }
    }
}
