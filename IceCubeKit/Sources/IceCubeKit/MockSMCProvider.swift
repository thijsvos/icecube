// MockSMCProvider.swift — deterministic thermal simulation of a 14" M2 Pro MacBook Pro (no hardware needed).

import Foundation

/// A simulated SMC for a 14" MacBook Pro (M2 Pro, Mac14,9): two fans and six
/// temperature sensors that behave plausibly without touching hardware. This
/// is the provider CI runs against, and what `ICECUBE_SIMULATED=1` selects.
///
/// ## How the simulation works
///
/// Every reading is a **pure function of the injected clock** — the actor holds
/// no mutable state and never touches `SystemRandomNumberGenerator`. Given the
/// same `now` closure, two providers (or two test runs) produce bit-identical
/// values. "Randomness" is hashed from the current time with SplitMix64, so
/// traces look organic but replay exactly.
///
/// The model, from the bottom up:
///
/// - **Sensors** idle around 38–50 °C. Each wanders on a slow sine (60–90 s
///   period) plus a faster small ripple, with per-sensor phases hashed from
///   the SMC key, so the six traces drift independently.
/// - **Workload spikes**: time is cut into fixed 180 s buckets. Most buckets
///   (85 %, decided by hashing the bucket index) contain one spike — 30–60 s
///   long, with a smooth 8 s rise, a flat plateau, and a 12 s cool-down —
///   that pushes the CPU and GPU toward 85–100 °C. Net effect: roughly every
///   2–4 minutes "something compiles".
/// - **Fan demand** maps the hottest sensor to 0…1: zero at or below 60 °C
///   (fans rest at minimum RPM), rising smoothly to one as the hottest sensor
///   approaches 95 °C (maximum RPM). `targetRPM` tracks demand instantly.
/// - **Fan inertia**: `actualRPM` chases `targetRPM` through a first-order
///   lag with a 10 s time constant, integrated on a fixed absolute-time grid.
///   Because the grid is anchored to wall time (multiples of 0.5 s since
///   1970), two consecutive reads are always consistent with the elapsed
///   time — the fan does not "teleport" between polls.
///
/// All values are clamped: temperatures to 20–110 °C and fan speeds to each
/// fan's `[minRPM, maxRPM]` — the same guarantee the real daemon enforces.
public actor MockSMCProvider: SMCProviding {
    /// The injected clock. Defaults to the real time; tests inject a fixed or
    /// manually-advanced clock to replay the simulation deterministically.
    private let now: @Sendable () -> Date

    /// - Parameter now: the clock the simulation runs on. Every reading is a
    ///   pure function of this clock's current `Date`.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fans() async throws(IceCubeError) -> [Fan] {
        Self.fans(at: now().timeIntervalSince1970)
    }

    public func temperatures() async throws(IceCubeError) -> [SensorReading] {
        Self.temperatures(at: now().timeIntervalSince1970)
    }

    /// The simulation has no power-gated clusters, so its inventory is simply
    /// its six sensors — every one reports on every tick. That is deliberate:
    /// simulated mode stays a stable target for the UI regardless of the
    /// admission rule real hardware needs.
    public func sensorInventory() async throws(IceCubeError) -> [SMCKeyMaps.SensorDescriptor] {
        Self.sensorSpecs.map { SMCKeyMaps.SensorDescriptor(key: $0.key, label: $0.label) }
    }

    public func power() async throws(IceCubeError) -> Double? {
        Self.power(at: now().timeIntervalSince1970)
    }

    /// A miniature key dump mirroring what the real provider reports for the same
    /// values, so the sensors browser and diagnostics export are fully
    /// demonstrable in simulated mode.
    ///
    /// (A simulated report is marked as such by `DiagnosticsReport.simulated` —
    /// it can never pass as a machine map.)
    public func keyDump() async throws(IceCubeError) -> [SMCKeyDump] {
        let t = now().timeIntervalSince1970
        var dump: [SMCKeyDump] = [
            entry(key: "#KEY", type: .uint32, value: Double(2 + Self.fanSpecs.count * 5 + Self.sensorSpecs.count)),
            entry(key: "FNum", type: .uint8, value: Double(Self.fanSpecs.count)),
        ]
        for fan in Self.fans(at: t) {
            dump.append(entry(key: "F\(fan.id)Ac", type: .float, value: fan.actualRPM))
            dump.append(entry(key: "F\(fan.id)Tg", type: .float, value: fan.targetRPM))
            dump.append(entry(key: "F\(fan.id)Mn", type: .float, value: fan.minRPM))
            dump.append(entry(key: "F\(fan.id)Mx", type: .float, value: fan.maxRPM))
            dump.append(entry(key: "F\(fan.id)Md", type: .uint8, value: Double(fan.mode.rawValue)))
        }
        for reading in Self.temperatures(at: t) {
            dump.append(entry(key: reading.key, type: .float, value: reading.celsius))
        }
        return dump
    }

    /// Builds one dump row with honest wire bytes (encoded exactly as the
    /// real SMC would report the value).
    private func entry(key: String, type: SMCDataType, value: Double) -> SMCKeyDump {
        let bytes = (try? SMCKeyCodec.encode(value, as: type)) ?? []
        return SMCKeyDump(
            key: key,
            type: type.rawValue,
            size: type.byteCount,
            value: (try? SMCKeyCodec.decodeDouble(bytes, as: type)) ?? value,
            text: nil,
            bytesHex: bytes.smcHexString
        )
    }
}
