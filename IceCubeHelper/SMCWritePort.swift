// SMCWritePort.swift — the ONLY SMC writer in the entire system (helper target; never linked into the app).

import Foundation
import IceCubeKit
import IOKit
import os

/// Read+write access to AppleSMC for the root daemon.
///
/// This file deliberately lives in the **IceCubeHelper target**, not IceCubeKit:
/// IceCubeKit is linked into the unprivileged app, and the app binary must not
/// contain SMC write code at all. The small duplication with the app's
/// read-only `SMCConnection` is the price of that guarantee.
///
/// Every write is audit-logged (key, value) before it happens, and the
/// firmware result byte is checked on every call — IOKit can report success
/// on an operation the firmware rejected.
actor SMCWritePort: SMCControlPort {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: (size: Int, type: String)] = [:]
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "smc")

    init() throws {
        connection = try Self.openSMCConnection()
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    /// FIELD CORRECTION (2026-07-23): thermalmonitord only reliably resumes
    /// driving the fans when the controlling process's SMC connection goes away
    /// (observed on Mac14,9: a daemon bounce restored system control; an in-place
    /// mode hand-back did not).
    ///
    /// Dropping and lazily reopening the connection after a revert reproduces
    /// that release without restarting the daemon.
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
            throw IceCubeError.smcConnectionFailed(kernReturn: kIOReturnNoDevice)
        }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess, conn != 0 else {
            throw IceCubeError.smcConnectionFailed(kernReturn: kr)
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
            throw IceCubeError.smcDecodingFailed(key: key, type: info.type, bytes: [])
        }
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = SMCCommand.readBytes
        let output = try call(&input, key: key)
        return try SMCKeyCodec.decodeDouble(output.dataBytes(info.size), as: type, forKey: key)
    }

    /// Writes one SMC key — the only path in the entire system that does.
    ///
    /// Audit-logged **before** the attempt, so a write the firmware rejects is
    /// visible in the log too, and the firmware result byte is checked on return:
    /// IOKit reports success on operations the SMC refused. The `bytes.count <= 32`
    /// guard is defence in depth — today's encoder yields at most 4 bytes — so a
    /// future wide type cannot silently write past the tuple.
    ///
    /// - Throws: ``IceCubeError/smcEncodingFailed(type:value:)`` when the value
    ///   does not fit `type`, or the transport/firmware error from `call(_:key:)`.
    func writeDouble(_ key: String, value: Double, as type: SMCDataType) async throws {
        let bytes = try SMCKeyCodec.encode(value, as: type)
        // Defense in depth: the 32-byte wire buffer can't be overrun (the
        // encoder only yields ≤4-byte payloads today), but assert it so a
        // future type can never silently write past the tuple.
        guard bytes.count <= 32 else {
            throw IceCubeError.smcEncodingFailed(type: type.name, value: value)
        }
        // Audit BEFORE the attempt so rejected writes are visible too.
        log.info("SMC write \(key, privacy: .public) = \(value, privacy: .public) (\(type.name, privacy: .public))")
        var input = SMCParamStruct()
        input.key = try SMCKeyCodec.keyCode(for: key)
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = SMCCommand.writeBytes
        // copyBytes carries its own "source fits destination" precondition,
        // so bounds safety is a stdlib guarantee rather than something the
        // hand-written loop and the count guard above maintain jointly. The
        // read side already uses the buffer API (SMCParamStruct.dataBytes).
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            raw.copyBytes(from: bytes)
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
            if kr == kIceCubeIONotPrivileged {
                throw IceCubeError.smcNotPrivileged(key: key)
            }
            throw IceCubeError.smcCallFailed(key: key, kernReturn: kr)
        }
        switch SMCResult(rawValue: output.result) {
        case .ok:
            return output
        case .keyNotFound:
            throw IceCubeError.smcKeyNotFound(key: key)
        case let result:
            // `format:` keeps the byte a typed os_log field, so Console and
            // `log show --predicate` can filter on it — and it zero-pads, where
            // String(_:radix:) logged 0x0A as "0xa". This path also runs inside
            // forceManualMode's 70-iteration ftst retry loop, so not building a
            // String per rejection matters.
            log.error(
                """
                SMC firmware rejected \(key, privacy: .public): \
                result \(result.rawValue, format: .hex(includePrefix: true, uppercase: true), privacy: .public)
                """
            )
            throw IceCubeError.smcFirmwareRejected(key: key, result: result)
        }
    }
}
