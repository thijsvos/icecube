// SMCControlPort.swift — the read+write SMC interface the write sequencer drives (real impl lives in the helper).

import Foundation

/// The minimal SMC surface the fan-control sequencer needs.
///
/// Only the **helper daemon** provides a real implementation (with the IOKit
/// write command); IceCubeKit itself ships no writer, and the app's read-only
/// `SMCConnection` does not conform. Tests drive the sequencer with scripted
/// fake firmwares (M1/M2 direct-accept, M3/M4 Ftst-unlock, M5 lowercase).
public protocol SMCControlPort: Sendable {
    func hasKey(_ key: String) async -> Bool
    func readDouble(_ key: String) async throws -> Double
    /// Writes `value` encoded as `type`, checking the firmware result byte.
    /// Throws `IceCubeError.smcFirmwareRejected` on result 0x82 (the M3+
    /// "thermalmonitord holds the fans" signal the sequencer reacts to).
    func writeDouble(_ key: String, value: Double, as type: SMCDataType) async throws
    /// Drops the underlying SMC connection, reopening lazily on next use.
    ///
    /// Not housekeeping: `thermalmonitord` only reliably resumes driving the
    /// fans once the controlling process's connection goes away (field-observed
    /// on Mac14,9), so this is part of handing control back.
    func reset() async
}

/// Where the daemon's persisted curve config lives.
///
/// A protocol so ``DaemonCore`` can be unit-tested. The real implementation
/// stays in the **helper target**: it enforces root ownership on the file and
/// its parent directory before trusting anything at boot, which is meaningless
/// (and untestable) outside a root daemon.
public protocol FanConfigStoring: Sendable {
    /// The persisted config, or `nil` when absent, invalid, or untrusted.
    func load() -> FanConfig?
    /// Saves `config` if it qualifies for persistence; clears otherwise.
    func save(_ config: FanConfig)
    /// Removes the persisted config.
    func clear()
}
