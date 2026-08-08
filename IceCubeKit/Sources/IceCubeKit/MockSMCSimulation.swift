// MockSMCSimulation.swift — the simulated thermal model: pure functions of a time value, no actor state.

import Foundation

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

    /// One bucket's scheduled workload: when it starts, how long, how hard.
    struct SpikeWindow: Sendable {
        let start: TimeInterval
        let duration: TimeInterval
        let intensity: Double
        var end: TimeInterval {
            start + duration
        }

        /// The flat stretch between the 8 s rise and the 12 s fall.
        var plateauStart: TimeInterval {
            start + 8
        }

        var plateauEnd: TimeInterval {
            end - 12
        }
    }

    /// The workload scheduled inside one 180 s bucket, or nil for a quiet one.
    ///
    /// Most buckets run one 30–60 s spike. About one spiking bucket in seven
    /// instead holds its plateau for the whole bucket: without a sustained
    /// load the fans' 10 s lag eats the short plateaus, so the simulated
    /// machine could never hold still *at speed* and a settled °C/W reading
    /// existed only at idle — half of THERMAL.md's measurement table was
    /// undemonstrable (its real table has exactly these two shapes: readings
    /// at ~3550 RPM and at ~5950 RPM).
    static func spikeWindow(inBucket bucket: Double) -> SpikeWindow? {
        let b = UInt64(bitPattern: Int64(bucket))
        guard unitNoise(b, 0) >= 0.15 else { return nil } // 15 % of buckets stay quiet
        let intensity = 0.8 + 0.2 * unitNoise(b, 2) // 0.8–1.0
        if unitNoise(b, 4) < 1.0 / 7.0 {
            // Sustained: fill the bucket, 12 s clear of each edge (~132 s flat).
            return SpikeWindow(
                start: bucket * spikeBucketLength + 12,
                duration: spikeBucketLength - 24,
                intensity: intensity
            )
        }
        let duration = 30 + 30 * unitNoise(b, 1) // 30–60 s
        // Keep the whole spike inside its bucket, ≥ 12 s clear of each edge.
        let start = bucket * spikeBucketLength + 12
            + (spikeBucketLength - duration - 24) * unitNoise(b, 3)
        return SpikeWindow(start: start, duration: duration, intensity: intensity)
    }

    /// Spike intensity at time `t`: 0 when no synthetic workload is running,
    /// otherwise 0.8–1.0 through a smooth rise (8 s) / plateau / fall (12 s).
    static func spikeEnvelope(at t: TimeInterval) -> Double {
        let bucket = (t / spikeBucketLength).rounded(.down)
        guard let window = spikeWindow(inBucket: bucket) else { return 0 }
        let elapsed = t - window.start
        guard elapsed > 0, elapsed < window.duration else { return 0 }
        return window.intensity
            * min(smoothstep(elapsed / 8), smoothstep((window.duration - elapsed) / 12))
    }

    /// How deep inside a steady stretch of the workload `t` sits: seconds to
    /// the nearest moment the spike envelope changes. Zero on a rise or fall.
    static func envelopeSteadiness(at t: TimeInterval) -> TimeInterval {
        let bucket = (t / spikeBucketLength).rounded(.down)
        if let window = spikeWindow(inBucket: bucket),
           t >= window.plateauStart, t <= window.plateauEnd
        {
            return min(t - window.plateauStart, window.plateauEnd - t)
        }
        guard spikeEnvelope(at: t) == 0 else { return 0 } // rising or falling
        // Quiet: the nearest changes are the previous spike's end and the next
        // spike's start. 85 % of buckets spike, so a short scan terminates;
        // the cap is a safety net, not a tuning knob.
        var sinceEnd = TimeInterval.infinity
        var untilStart = TimeInterval.infinity
        for offset in 0 ... 8 {
            if sinceEnd.isInfinite,
               let w = spikeWindow(inBucket: bucket - Double(offset)), w.end <= t
            {
                sinceEnd = t - w.end
            }
            if untilStart.isInfinite,
               let w = spikeWindow(inBucket: bucket + Double(offset)), w.start >= t
            {
                untilStart = w.start - t
            }
        }
        return min(sinceEnd, untilStart)
    }

    /// Damping applied to the slow sine wander deep inside a steady stretch.
    ///
    /// The real machine settles — THERMAL.md's whole measurement table is
    /// settled readings — but the model's ±2.2 °C / 72 s wander never stopped:
    /// under the settle rule the simulation held still on ~1 % of its ticks,
    /// in runs of a few seconds, so the °C/W readout read "—" in every demo
    /// (CLAUDE.md ground rule 3). Damping only *away* from envelope
    /// transitions keeps temperature continuous — within 10 s of a rise or
    /// fall the scale is exactly 1 — while a machine that has been doing the
    /// same thing for half a minute becomes as steady as the real one: by
    /// 25 s the wander is at 15 %, putting damped wander (±0.33 °C) plus the
    /// fast ripple (±0.4 °C) comfortably inside the settle rule's 1.5 °C
    /// without making the trace look dead.
    static func wanderScale(at t: TimeInterval) -> Double {
        1 - 0.85 * smoothstep((envelopeSteadiness(at: t) - 10) / 15)
    }

    // MARK: SoC power

    /// Idle and peak SoC package power, in watts.
    ///
    /// Taken from the real machine rather than invented: `PSTR` on a Mac14,9
    /// read **19.6 W idle and ~52 W peak under a Release build** (measured
    /// 2026-07-28), so the simulation spans a range a reader can sanity-check
    /// against their own hardware.
    static let idleWatts = 19.6
    static let peakWatts = 52.0

    /// Simulated SoC package power in watts at time `t`.
    ///
    /// Tracks the same workload envelope the sensors do. It is deliberately NOT
    /// given a head start over the thermal model: on real hardware the two move
    /// within a couple of seconds of each other (docs/SMC-KEYS.md), and a
    /// simulation that invented a lead would make any future control idea built
    /// on it look far better in CI than it is on the owner's desk.
    static func power(at t: TimeInterval) -> Double {
        idleWatts + (peakWatts - idleWatts) * spikeEnvelope(at: t)
    }

    // MARK: Sensors

    /// All six sensors at time `t`, each clamped to 20–110 °C.
    ///
    /// The spike and the wander scale are hoisted: both are per-instant, not
    /// per-sensor, and `laggedDemand` re-evaluates this at ~160 grid points
    /// per fan read.
    static func temperatures(at t: TimeInterval) -> [SensorReading] {
        let spike = spikeEnvelope(at: t)
        let scale = wanderScale(at: t)
        return sensorSpecs.map { spec in
            SensorReading(
                key: spec.key,
                label: spec.label,
                celsius: temperature(of: spec, at: t, spike: spike, wanderScale: scale)
            )
        }
    }

    /// One sensor's temperature: idle base + slow sine wander (damped deep in
    /// steady stretches, see ``wanderScale(at:)``) + fast ripple + the spike
    /// contribution, clamped to the model's 20–110 °C bounds.
    static func temperature(
        of spec: SensorSpec, at t: TimeInterval, spike: Double, wanderScale: Double
    ) -> Double {
        let seed = seed(forKey: spec.key)
        let wanderPhase = 2 * .pi * unitNoise(seed, 10)
        let ripplePhase = 2 * .pi * unitNoise(seed, 11)
        let ripplePeriod = 11 + 12 * unitNoise(seed, 12) // 11–23 s, per sensor
        let wander = spec.wanderAmp * wanderScale
            * sin(2 * .pi * t / spec.wanderPeriod + wanderPhase)
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

    /// Demand filtered through the first-order lag — what fraction of the range
    /// the fan has physically reached.
    ///
    /// Integrated over the last 80 s (8 time constants, so the arbitrary starting
    /// value has decayed to ~0.03 %) on a grid of absolute 0.5 s steps. Anchoring
    /// the grid to wall time makes consecutive reads mutually consistent.
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
