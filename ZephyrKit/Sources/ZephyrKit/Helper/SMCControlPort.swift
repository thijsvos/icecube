// SMCControlPort.swift — the read+write SMC interface the write sequencer drives (real impl lives in the helper).

import Foundation

/// The minimal SMC surface the fan-control sequencer needs.
///
/// Only the **helper daemon** provides a real implementation (with the IOKit
/// write command); ZephyrKit itself ships no writer, and the app's read-only
/// `SMCConnection` does not conform. Tests drive the sequencer with scripted
/// fake firmwares (M1/M2 direct-accept, M3/M4 Ftst-unlock, M5 lowercase).
public protocol SMCControlPort: Sendable {
    func hasKey(_ key: String) async -> Bool
    func readDouble(_ key: String) async throws -> Double
    /// Writes `value` encoded as `type`, checking the firmware result byte.
    /// Throws `ZephyrError.smcFirmwareRejected` on result 0x82 (the M3+
    /// "thermalmonitord holds the fans" signal the sequencer reacts to).
    func writeDouble(_ key: String, value: Double, as type: SMCDataType) async throws
}
