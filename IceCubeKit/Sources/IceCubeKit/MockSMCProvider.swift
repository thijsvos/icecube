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

    /// A miniature key dump mirroring what the real provider reports for the
    /// same values, so the sensors browser and diagnostics export are fully
    /// demonstrable in simulated mode. (A simulated report is marked as such
    /// by `DiagnosticsReport.simulated` — it can never pass as a machine map.)
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

// MARK: - The simulation model

//
// Everything below is `static` and internal: pure functions of a time value,
// with no actor state. Tests call these directly (via `@testable import`) to
// locate spikes and quiet stretches on the simulated timeline.

extension MockSMCProvider {
    /// Fixed description of one simulated fan (values read from a real Mac14,9).
    struct FanSpec: Sendable {
        let id: Int
        let name: String
        let minRPM: Double
        let maxRPM: Double
    }

    /// Fixed description of one simulated sensor: where it idles, how far and
    /// how fast it wanders, and how hard a workload spike pushes it.
    struct SensorSpec: Sendable {
        let key: String
        let label: String
        /// Resting temperature in °C, no load.
        let idle: Double
        /// Amplitude of the slow sine wander, °C.
        let wanderAmp: Double
        /// Period of the slow sine wander, seconds (60–90 s per the model).
        let wanderPeriod: Double
        /// °C added at full spike intensity. CPU/GPU are high; SSD/battery low.
        let spikeGain: Double
    }

    /// The two fans of a 14" M2 Pro MacBook Pro (ranges read from the real
    /// Mac14,9 via `icecube-diag`: both report `F{i}Mn` 2317, `F{i}Mx` 6800).
    static let fanSpecs: [FanSpec] = [
        FanSpec(id: 0, name: "Left", minRPM: 2317, maxRPM: 6800),
        FanSpec(id: 1, name: "Right", minRPM: 2317, maxRPM: 6800),
    ]

    /// Six M2-generation sensors. Keys match what the real SMC exposes.
    static let sensorSpecs: [SensorSpec] = [
        SensorSpec(key: "Tp01", label: "CPU P-cores", idle: 47.0, wanderAmp: 2.2, wanderPeriod: 72, spikeGain: 49),
        SensorSpec(key: "Tp1h", label: "CPU E-cores", idle: 44.0, wanderAmp: 1.8, wanderPeriod: 84, spikeGain: 41),
        SensorSpec(key: "Tg0f", label: "GPU", idle: 42.0, wanderAmp: 2.0, wanderPeriod: 66, spikeGain: 47),
        SensorSpec(key: "TH0x", label: "SSD", idle: 40.0, wanderAmp: 1.2, wanderPeriod: 90, spikeGain: 7),
        SensorSpec(key: "TB1T", label: "Battery", idle: 38.5, wanderAmp: 0.8, wanderPeriod: 78, spikeGain: 3),
        SensorSpec(key: "TaLP", label: "Airflow Left", idle: 39.5, wanderAmp: 1.5, wanderPeriod: 61, spikeGain: 10),
    ]

    /// First-order lag time constant for `actualRPM` chasing `targetRPM`, s.
    static let fanTimeConstant: TimeInterval = 10
    /// Length of one workload-spike scheduling bucket, s.
    static let spikeBucketLength: TimeInterval = 180
    /// Demand is 0 at or below this hottest-sensor temperature, °C.
    static let demandFloorCelsius = 60.0
    /// Demand reaches 1 (maximum RPM) at this hottest-sensor temperature, °C.
    static let demandCeilingCelsius = 95.0

    // MARK: Deterministic pseudo-randomness

    /// SplitMix64 finalizer: scrambles the bits of `x` into a well-mixed value.
    /// Same input, same output — this is the only "random" source in the file.
    private static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Deterministic "random" number in [0, 1) derived from the given seeds.
    static func unitNoise(_ seeds: UInt64...) -> Double {
        var mixed: UInt64 = 0x243F_6A88_85A3_08D3 // arbitrary fixed constant (digits of pi)
        for seed in seeds {
            mixed = splitmix64(mixed ^ seed)
        }
        return Double(mixed >> 11) * 0x1p-53
    }

    /// Stable 64-bit seed for a sensor key (FNV-1a over UTF-8). We must not
    /// use `hashValue` here: Swift seeds it per process, which would break
    /// run-to-run determinism.
    static func seed(forKey key: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Clamped cubic ease: 0 for x ≤ 0, 1 for x ≥ 1, smooth in between.
    static func smoothstep(_ x: Double) -> Double {
        let c = x.clamped(to: 0 ... 1)
        return c * c * (3 - 2 * c)
    }

    // MARK: Workload spikes

    /// Spike intensity at time `t`: 0 when no synthetic workload is running,
    /// otherwise 0.8–1.0 through a smooth rise (8 s) / plateau / fall (12 s).
    /// One spike is scheduled pseudo-randomly inside most 180 s buckets.
    static func spikeEnvelope(at t: TimeInterval) -> Double {
        let bucket = (t / spikeBucketLength).rounded(.down)
        let b = UInt64(bitPattern: Int64(bucket))
        guard unitNoise(b, 0) >= 0.15 else { return 0 } // 15 % of buckets stay quiet
        let duration = 30 + 30 * unitNoise(b, 1) // 30–60 s
        let intensity = 0.8 + 0.2 * unitNoise(b, 2) // 0.8–1.0
        // Keep the whole spike inside its bucket, ≥ 12 s clear of each edge.
        let start = bucket * spikeBucketLength + 12
            + (spikeBucketLength - duration - 24) * unitNoise(b, 3)
        let elapsed = t - start
        guard elapsed > 0, elapsed < duration else { return 0 }
        return intensity * min(smoothstep(elapsed / 8), smoothstep((duration - elapsed) / 12))
    }

    // MARK: Sensors

    /// All six sensors at time `t`, each clamped to 20–110 °C.
    static func temperatures(at t: TimeInterval) -> [SensorReading] {
        let spike = spikeEnvelope(at: t)
        return sensorSpecs.map { spec in
            SensorReading(
                key: spec.key,
                label: spec.label,
                celsius: temperature(of: spec, at: t, spike: spike)
            )
        }
    }

    /// One sensor's temperature: idle base + slow sine wander + fast ripple
    /// + the spike contribution, clamped to the model's 20–110 °C bounds.
    static func temperature(of spec: SensorSpec, at t: TimeInterval, spike: Double) -> Double {
        let seed = seed(forKey: spec.key)
        let wanderPhase = 2 * .pi * unitNoise(seed, 10)
        let ripplePhase = 2 * .pi * unitNoise(seed, 11)
        let ripplePeriod = 11 + 12 * unitNoise(seed, 12) // 11–23 s, per sensor
        let wander = spec.wanderAmp * sin(2 * .pi * t / spec.wanderPeriod + wanderPhase)
            + 0.4 * sin(2 * .pi * t / ripplePeriod + ripplePhase)
        return (spec.idle + wander + spike * spec.spikeGain).clamped(to: 20 ... 110)
    }

    // MARK: Fans

    /// Instantaneous fan demand in 0…1: what fraction of the min→max range
    /// the auto controller wants, given the hottest sensor right now.
    static func demand(at t: TimeInterval) -> Double {
        let hottest = temperatures(at: t).map(\.celsius).max() ?? 0
        return smoothstep((hottest - demandFloorCelsius)
            / (demandCeilingCelsius - demandFloorCelsius))
    }

    /// Demand filtered through the first-order lag — what fraction of the
    /// range the fan has physically reached. Integrated over the last 80 s
    /// (8 time constants, so the arbitrary starting value has decayed to
    /// ~0.03 %) on a grid of absolute 0.5 s steps. Anchoring the grid to
    /// wall time makes consecutive reads mutually consistent.
    static func laggedDemand(at t: TimeInterval) -> Double {
        let gridStep = 0.5 // power of two, so grid points are exact Doubles
        let horizon = 8 * fanTimeConstant
        var gridTime = ((t - horizon) / gridStep).rounded(.down) * gridStep
        var value = demand(at: gridTime)
        while gridTime + gridStep <= t {
            gridTime += gridStep
            value = lagStep(value, toward: demand(at: gridTime), over: gridStep)
        }
        if t > gridTime {
            value = lagStep(value, toward: demand(at: t), over: t - gridTime)
        }
        return value
    }

    /// Exact first-order-lag update over `dt` for a constant target:
    /// the gap to the target shrinks by a factor of e^(−dt/τ).
    private static func lagStep(
        _ value: Double,
        toward target: Double,
        over dt: TimeInterval
    ) -> Double {
        target + (value - target) * exp(-dt / fanTimeConstant)
    }

    /// Both fans at time `t`, in `.system` mode (macOS in control), with
    /// target and actual RPM clamped to `[minRPM, maxRPM]`.
    static func fans(at t: TimeInterval) -> [Fan] {
        let target = demand(at: t)
        let lagged = laggedDemand(at: t)
        return fanSpecs.map { spec in
            let range = spec.maxRPM - spec.minRPM
            return Fan(
                id: spec.id,
                name: spec.name,
                mode: .system,
                actualRPM: (spec.minRPM + lagged * range).clamped(to: spec.minRPM ... spec.maxRPM),
                targetRPM: (spec.minRPM + target * range).clamped(to: spec.minRPM ... spec.maxRPM),
                minRPM: spec.minRPM,
                maxRPM: spec.maxRPM
            )
        }
    }
}
