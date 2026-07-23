// SMCWritePort.swift — the ONLY SMC writer in the entire system (helper target; never linked into the app).

import Foundation
import IOKit
import os
import ZephyrKit

/// Read+write access to AppleSMC for the root daemon.
///
/// This file deliberately lives in the **ZephyrHelper target**, not ZephyrKit:
/// ZephyrKit is linked into the unprivileged app, and the app binary must not
/// contain SMC write code at all. The small duplication with the app's
/// read-only `SMCConnection` is the price of that guarantee.
///
/// Every write is audit-logged (key, value) before it happens, and the
/// firmware result byte is checked on every call — IOKit can report success
/// on an operation the firmware rejected.
actor SMCWritePort: SMCControlPort {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: (size: Int, type: String)] = [:]
    private let log = Logger(subsystem: "io.github.thijsvos.zephyr", category: "smc")

    init() throws {
        connection = try Self.openSMCConnection()
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    /// FIELD CORRECTION (2026-07-23): thermalmonitord only reliably resumes
    /// driving the fans when the controlling process's SMC connection goes
    /// away (observed on Mac14,9: a daemon bounce restored system control;
    /// an in-place mode hand-back did not). Dropping and lazily reopening
    /// the connection after a revert reproduces that release without
    /// restarting the daemon.
    func reset() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        keyInfoCache.removeAll()
        log.notice("SMC connection reset (will reopen on next use)")
    }

    /// Static so it is callable from the (nonisolated) actor init and from
    /// isolated methods alike.
    private static func openSMCConnection() throws -> io_connect_t {
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
        return conn
    }

    // MARK: - SMCControlPort

    func hasKey(_ key: String) async -> Bool {
        (try? keyInfo(for: key)) != nil
    }

    func readDouble(_ key: String) async throws -> Double {
        let info = try keyInfo(for: key)
        guard let type = SMCDataType(rawValue: info.type) else {
            throw ZephyrError.smcDecodingFailed(key: key, type: info.type, bytes: [])
        }
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = SMCCommand.readBytes
        let output = try call(&input, key: key)
        return try SMCKeyCodec.decodeDouble(output.dataBytes(info.size), as: type, forKey: key)
    }

    func writeDouble(_ key: String, value: Double, as type: SMCDataType) async throws {
        let bytes = try SMCKeyCodec.encode(value, as: type)
        // Audit BEFORE the attempt so rejected writes are visible too.
        log.info("SMC write \(key, privacy: .public) = \(value, privacy: .public) (\(type.name, privacy: .public))")
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = SMCCommand.writeBytes
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, byte) in bytes.enumerated() {
                raw[i] = byte
            }
        }
        _ = try call(&input, key: key)
    }

    // MARK: - Plumbing

    private func keyInfo(for key: String) throws -> (size: Int, type: String) {
        if let cached = keyInfoCache[key] {
            return cached
        }
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.data8 = SMCCommand.readKeyInfo
        let output = try call(&input, key: key)
        let info = (
            size: Int(output.keyInfo.dataSize),
            type: (try? SMCKeyCodec.keyString(from: output.keyInfo.dataType)) ?? "????"
        )
        keyInfoCache[key] = info
        return info
    }

    private func call(_ input: inout SMCParamStruct, key: String) throws -> SMCParamStruct {
        if connection == 0 {
            connection = try Self.openSMCConnection() // lazily reopen after reset()
        }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection, kSMCSelectorHandleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
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
            log
                .error(
                    "SMC firmware rejected \(key, privacy: .public): result 0x\(String(output.result, radix: 16), privacy: .public)"
                )
            throw ZephyrError.smcFirmwareRejected(key: key, result: output.result)
        }
    }
}
