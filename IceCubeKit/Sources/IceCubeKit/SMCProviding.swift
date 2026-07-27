// SMCProviding.swift — the read-only hardware abstraction all UI and feature code must go through.

import Foundation

/// Read-only access to SMC-reported fans and temperature sensors.
///
/// This protocol is deliberately **read-only**. Nothing in the app process ever
/// writes to the SMC: all writes happen in the privileged helper daemon behind a
/// separate daemon-side service (Phase 3), where they are clamped to each fan's
/// safe range and audited. A buggy or compromised UI therefore cannot command
/// the hardware directly.
///
/// Implementations:
/// - `MockSMCProvider` — thermal simulation; the default in CI and whenever
///   `ICECUBE_SIMULATED=1` (or `--simulated`) is set.
/// - `SystemSMCProvider` — real IOKit reads (Phase 1). Reads need no root.
public protocol SMCProviding: Sendable {
    /// All fans the SMC reports, discovered via `FNum` and the per-fan
    /// `F{i}Ac` / `F{i}Tg` / `F{i}Mn` / `F{i}Mx` keys.
    func fans() async throws(IceCubeError) -> [Fan]

    /// All monitored temperature sensors, in degrees Celsius.
    func temperatures() async throws(IceCubeError) -> [SensorReading]

    /// Every SMC key this machine exposes, with metadata and a best-effort
    /// decoded value — the raw material of the sensors browser and the
    /// diagnostics report.
    ///
    /// Expensive (thousands of reads on real hardware): call on demand, never
    /// from the polling loop.
    func keyDump() async throws(IceCubeError) -> [SMCKeyDump]
}

public extension SMCProviding {
    /// One timestamped reading of everything — the unit that polling publishes
    /// and charts consume.
    func snapshot() async throws(IceCubeError) -> SMCSnapshot {
        try await SMCSnapshot(date: Date(), fans: fans(), temperatures: temperatures())
    }
}
