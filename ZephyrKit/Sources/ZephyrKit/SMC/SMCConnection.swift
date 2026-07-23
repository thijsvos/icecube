// SMCConnection.swift — the one IOKit doorway to AppleSMC: read-only calls, key-info cache, key enumeration.

import Foundation
import IOKit

/// A live connection to the `AppleSMC` IOKit service, exposing exactly the
/// read-side operations Phase 1 needs: key info (cached), value reads, and
/// index-based key enumeration for the sensors browser.
///
/// **There is deliberately no write method.** SMC writes require root and are
/// the helper daemon's monopoly (Phase 3); keeping the method off this type
/// means the app process contains no code path that could write, even by
/// accident.
///
/// An actor, so calls are serialized on one connection — the SMC dislikes
/// concurrent callers on a single `io_connect_t`.
public actor SMCConnection {
    /// Key metadata as reported by the firmware, cached per key (key info is
    /// immutable for the lifetime of a boot, so one query per key suffices).
    public struct KeyInfo: Sendable, Equatable {
        /// Value size in bytes (1…32).
        public let size: Int
        /// The 4-character type code, e.g. `"flt "` — see `SMCDataType`.
        public let type: String
        /// Firmware attribute bits (bit 7 read, bit 6 write — advisory).
        public let attributes: UInt8
    }

    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: KeyInfo] = [:]

    /// Opens the AppleSMC service. Reads need no privileges — this works in
    /// the unprivileged app process and in CI-less local runs alike.
    ///
    /// - Throws: `ZephyrError.smcConnectionFailed` if the service is missing
    ///   (non-Mac?) or refuses the connection.
    public init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            throw ZephyrError.smcConnectionFailed(kernReturn: kIOReturnNoDevice)
        }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess, conn != 0 else {
            throw ZephyrError.smcConnectionFailed(kernReturn: kr)
        }
        connection = conn
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    // MARK: - Public reads

    /// The firmware's metadata for `key`, from cache when available.
    ///
    /// - Throws: `ZephyrError.smcKeyNotFound` if the key does not exist on
    ///   this machine; other `ZephyrError` cases for transport failures.
    public func keyInfo(for key: String) throws -> KeyInfo {
        if let cached = keyInfoCache[key] {
            return cached
        }
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.data8 = SMCCommand.readKeyInfo
        let output = try call(&input, key: key)
        let info = KeyInfo(
            size: Int(output.keyInfo.dataSize),
            type: (try? SMCKeyCodec.keyString(from: output.keyInfo.dataType)) ?? "????",
            attributes: output.keyInfo.dataAttributes
        )
        keyInfoCache[key] = info
        return info
    }

    /// True if `key` exists on this machine (a cached key-info probe).
    public func hasKey(_ key: String) -> Bool {
        (try? keyInfo(for: key)) != nil
    }

    /// Reads `key`'s raw bytes plus its metadata.
    public func readBytes(_ key: String) throws -> (bytes: [UInt8], info: KeyInfo) {
        let info = try keyInfo(for: key)
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = SMCCommand.readBytes
        let output = try call(&input, key: key)
        return (output.dataBytes(info.size), info)
    }

    /// Reads `key` and decodes it as a number using its firmware-reported type.
    ///
    /// - Throws: `ZephyrError.smcDecodingFailed` when the reported type is one
    ///   Zephyr has no numeric decoding for (see `SMCDataType`).
    public func readDouble(_ key: String) throws -> Double {
        let (bytes, info) = try readBytes(key)
        guard let type = SMCDataType(rawValue: info.type) else {
            throw ZephyrError.smcDecodingFailed(key: key, type: info.type, bytes: bytes)
        }
        return try SMCKeyCodec.decodeDouble(bytes, as: type, forKey: key)
    }

    /// Reads a `{fds` fan-descriptor key and decodes its name field.
    public func readString(_ key: String) throws -> String {
        let (bytes, _) = try readBytes(key)
        return try SMCKeyCodec.decodeString(bytes, forKey: key)
    }

    // MARK: - Enumeration (powers the sensors browser + diagnostics)

    /// Total number of keys this machine's SMC exposes (the `#KEY` count).
    public func keyCount() throws -> Int {
        try Int(readDouble("#KEY"))
    }

    /// The key name at enumeration index `index` (0-based).
    ///
    /// - Throws: `ZephyrError.smcDecodingFailed` for keys whose 4 characters
    ///   are not printable ASCII (rare firmware oddities — callers skip them).
    public func key(atIndex index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = SMCCommand.readKeyByIndex
        input.data32 = UInt32(index)
        let output = try call(&input, key: "#\(index)")
        return try SMCKeyCodec.keyString(from: output.key)
    }

    // MARK: - The one place that talks to IOKit

    /// Performs one SMC call and applies the project's error discipline:
    /// check `kern_return_t` first, then **always** the firmware result byte
    /// (IOKit can report success on a firmware-rejected operation).
    private func call(_ input: inout SMCParamStruct, key: String) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCSelectorHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard kr == kIOReturnSuccess else {
            if kr == kZephyrIONotPrivileged {
                throw ZephyrError.smcNotPrivileged(key: key)
            }
            throw ZephyrError.smcCallFailed(key: key, kernReturn: kr)
        }
        switch output.result {
        case SMCResult.ok:
            return output
        case SMCResult.keyNotFound:
            throw ZephyrError.smcKeyNotFound(key: key)
        default:
            throw ZephyrError.smcFirmwareRejected(key: key, result: output.result)
        }
    }
}
