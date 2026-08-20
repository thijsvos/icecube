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
    ///
    /// Only sensors that have reported at least once this process — a
    /// power-gated cluster can be silent for up to ~85 s after launch, and no
    /// row beats an invented one. Compare ``sensorInventory()``.
    func temperatures() async throws(IceCubeError) -> [SensorReading]

    /// The sensors this machine **has**, independent of what is reporting at
    /// this instant.
    ///
    /// Separate from ``temperatures()`` because the two answer different
    /// questions, and the difference is the whole subject of
    /// ``SensorAdmission``: membership is a property of the Mac and is stable
    /// from the first poll, while the reporting set legitimately varies as
    /// clusters gate on and off.
    func sensorInventory() async throws(IceCubeError) -> [SMCKeyMaps.SensorDescriptor]

    /// Total **system** power in watts (`PSTR`), or `nil` when this Mac exposes no
    /// usable key (see ``SMCKeyMaps/powerKeyCandidates``).
    ///
    /// `nil` is a first-class answer, not a failure — a Mac without the key
    /// simply has no wattage to show, and callers omit the figure rather than
    /// substituting a guess. Reported for diagnostics only: power is **not** an
    /// input to fan control, and docs/SMC-KEYS.md records the measurements
    /// explaining why it should not become one.
    func power() async throws(IceCubeError) -> Double?

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
        // Power is read last and its failure is swallowed on purpose. A Mac
        // with no `PSTR`/`PDTR` must still get fans and temperatures — the
        // whole app depends on those, and watts is an extra. `power()` already
        // returns nil for "no such key"; the `try?` covers a transport hiccup
        // on a machine that does have one. `try?` already flattens the
        // `Double?` this returns (SE-0230), so no `?? nil` is needed to get
        // back to one level of optional — there was one, and it did nothing.
        try await SMCSnapshot(
            date: Date(),
            fans: fans(),
            temperatures: temperatures(),
            power: try? power()
        )
    }
}
