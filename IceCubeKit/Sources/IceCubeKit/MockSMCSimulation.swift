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
    /// how fast it wanders, and how much of the machine's heat reaches it.
    struct SensorSpec: Sendable {
        let key: String
        let label: String
        /// Resting temperature in °C, no load.
        let idle: Double
        /// Amplitude of the slow sine wander, °C.
        let wanderAmp: Double
        /// Period of the slow sine wander, seconds (60–90 s per the model).
        let wanderPeriod: Double
        /// Share of the die's rise this sensor sees, 0…1. The die itself is
        /// 1.0; the SSD and battery barely move; airflow sits in between.
        ///
        /// Replaced `spikeGain` (°C at full workload intensity) on
        /// 2026-09-01. The shares are the old gains divided by the die's 49,
        /// so every sensor keeps the character it had — what changed is where
        /// the number driving them comes from. `spikeGain` read the workload
        /// envelope directly, which is why the fans could not cool anything:
        /// see ``equilibriumRise(watts:fanFraction:)``.
        let riseShare: Double
    }

    /// The two fans of a 14" M2 Pro MacBook Pro (ranges read from the real
    /// Mac14,9 via `icecube-diag`: both report `F{i}Mn` 2317, `F{i}Mx` 6800).
    static let fanSpecs: [FanSpec] = [
        FanSpec(id: 0, name: "Left", minRPM: 2317, maxRPM: 6800),
        FanSpec(id: 1, name: "Right", minRPM: 2317, maxRPM: 6800),
    ]

    /// Six M2-generation sensors. Keys match what the real SMC exposes.
    ///
    /// `riseShare` is the old `spikeGain` over the die's 49, so the sensors
    /// keep their measured relative behaviour: airflow rises about a fifth as
    /// much as the die, and the battery barely at all.
    static let sensorSpecs: [SensorSpec] = [
        SensorSpec(key: "Tp01", label: "CPU P-cores", idle: 47.0, wanderAmp: 2.2, wanderPeriod: 72, riseShare: 1.00),
        SensorSpec(key: "Tp1h", label: "CPU E-cores", idle: 44.0, wanderAmp: 1.8, wanderPeriod: 84, riseShare: 0.84),
        SensorSpec(key: "Tg0f", label: "GPU", idle: 42.0, wanderAmp: 2.0, wanderPeriod: 66, riseShare: 0.96),
        SensorSpec(key: "TH0x", label: "SSD", idle: 40.0, wanderAmp: 1.2, wanderPeriod: 90, riseShare: 0.14),
        SensorSpec(key: "TB1T", label: "Battery", idle: 38.5, wanderAmp: 0.8, wanderPeriod: 78, riseShare: 0.06),
        SensorSpec(key: "TaLP", label: "Airflow Left", idle: 39.5, wanderAmp: 1.5, wanderPeriod: 61, riseShare: 0.20),
    ]

    /// The sensor the simulated auto-controller watches.
    ///
    /// Hoisted out of the integration loop, which evaluates the control
    /// signal once per grid step. `Tp01` both idles hottest and has the
    /// largest ``SensorSpec/riseShare``, so it leads at every load and the
    /// choice cannot switch mid-run — asserted in `MockSMCProviderTests`
    /// rather than assumed.
    static let controlSensor: SensorSpec = sensorSpecs
        .max { ($0.idle + 50 * $0.riseShare) < ($1.idle + 50 * $1.riseShare) } ?? sensorSpecs[0]

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

    // MARK: System power

    /// Idle and peak **system** power, in watts — the whole machine, not the SoC
    /// package.
    ///
    /// Taken from the real machine rather than invented: `PSTR` on a Mac14,9
    /// read **19.6 W idle and ~52 W peak under a Release build** (measured
    /// 2026-07-28), so the simulation spans a range a reader can sanity-check
    /// against their own hardware. Named carefully: this said "SoC package
    /// power" until 2026-08-16, and `SMCKeyMaps.powerKeyCandidates` already
    /// records that several places once made that mistake and were wrong. It
    /// matters wherever this is divided into a die temperature — see
    /// docs/THERMAL.md.
    static let idleWatts = 19.6
    static let peakWatts = 52.0

    /// Simulated total system power in watts at time `t`.
    ///
    /// Tracks the same workload envelope the sensors do. It is deliberately NOT
    /// given a head start over the thermal model: the measured lead on real
    /// hardware is somewhere between −2 and +9 seconds depending on the
    /// threshold and what the machine was already doing (docs/SMC-KEYS.md), and
    /// far less than the ~16 s of smoothing it would take to stop a single
    /// 2-second burst spinning the fans. A simulation that invented a clean lead
    /// would make any future control idea built on it look far better in CI than
    /// it is on the owner's desk.
    static func power(at t: TimeInterval) -> Double {
        idleWatts + (peakWatts - idleWatts) * spikeEnvelope(at: t)
    }

    // MARK: The cooling law — what the fans actually buy

    /// System watts that never reach the die.
    ///
    /// Display, SSD, charging losses, and the die's own resting dissipation,
    /// which is already baked into each sensor's `idle`. Anchored to the
    /// **7.9 W true idle** `docs/THERMAL.md` measured on a Mac14,9 plus the
    /// difference between that and the 19.6 W the same file records with
    /// background work running: below this draw the die sits at its resting
    /// temperature and the fans have nothing to remove.
    static let freeWatts = 18.0

    /// Die rise per marginal watt with the fans at rest, °C/W.
    static let slopeAtRest = 2.20

    /// Die rise per marginal watt with the fans at maximum, °C/W.
    ///
    /// The pair with ``slopeAtRest`` is what makes the fans in this model
    /// cool. Calibrated so the resulting `R = ΔT/P` lands on
    /// `docs/THERMAL.md`'s measured table rather than being invented: at
    /// 19.6 W with the fans at rest the die settles ~3.5 °C over its base and
    /// airflow ~0.7 °C over its own, giving R ≈ 0.52 against the measured
    /// **0.51**; at 48 W with the fans at 95 % it gives R ≈ 0.86 against the
    /// measured **0.90**. Crucially the *direction* is now right — R falls as
    /// the fans rise, which is the one thing the old model got backwards.
    static let slopeAtFull = 1.40

    /// The die's own fast pole (silicon → heat spreader), seconds.
    static let dieFastTimeConstant: TimeInterval = 6

    /// The slow pole (spreader → heatsink → air), seconds.
    ///
    /// The two poles are modelled separately on purpose. A single-pole
    /// simulation would be a rigged test for anything that *fits* a single
    /// pole to it — the fit would be exact, and the same code would meet a
    /// two-pole machine on real hardware. Real silicon responds in seconds
    /// while the chassis takes minutes, and a model that pretends otherwise
    /// flatters whatever is built on it.
    static let dieSlowTimeConstant: TimeInterval = 75

    /// Share of the die's rise carried by the fast pole.
    static let dieFastShare = 0.70

    /// Where the die settles above its resting temperature, given the work
    /// being done and how hard the fans are running.
    ///
    /// **This is the function the old model did not have.** Temperature used
    /// to read the workload envelope directly, so the fans responded to heat
    /// and never removed any — `SimulatedCoolingHistory` documents the
    /// consequence, that its `R` moved the opposite way from real hardware
    /// and the cooling history had to be fabricated rather than recorded.
    ///
    /// Linear in the fan fraction between ``slopeAtRest`` and
    /// ``slopeAtFull``. That is an approximation — real heat transfer goes
    /// roughly as a fractional power of airflow — but it is monotonic, it
    /// reproduces the measured endpoints, and `docs/THERMAL.md` only has two
    /// fan speeds to argue with. A third measured speed is the reason to
    /// change it.
    static func equilibriumRise(watts: Double, fanFraction: Double) -> Double {
        let fraction = fanFraction.clamped(to: 0 ... 1)
        let slope = slopeAtRest + (slopeAtFull - slopeAtRest) * fraction
        return max(0, slope * (watts - freeWatts))
    }

    // MARK: The coupled state

    /// The simulated machine's two integrated quantities: how far the die has
    /// risen above its resting temperature, and where the fans have actually
    /// got to.
    ///
    /// They have to be integrated **together**. The die's temperature depends
    /// on the fan speed, the fan speed depends on the die's temperature, and
    /// resolving either alone would recurse forever — which is the shape of
    /// the problem the old model dodged by having no feedback at all.
    struct ThermalState: Sendable, Equatable {
        /// The fast pole's contribution, °C.
        var fastRise: Double
        /// The slow pole's contribution, °C.
        var slowRise: Double
        /// Fraction of the fans' min→max range physically reached, 0…1.
        var fanFraction: Double

        /// The die's rise above its resting temperature, °C.
        var dieRise: Double {
            dieFastShare * fastRise + (1 - dieFastShare) * slowRise
        }
    }

    /// Integration grid, seconds. A power of two, so grid points are exact
    /// `Double`s and the wall-time anchor is reproducible.
    static let stateGridStep: TimeInterval = 0.5

    /// How far back the integration starts, seconds.
    ///
    /// Six slow time constants, and the walk **begins at that moment's own
    /// equilibrium** rather than at zero, so the residual from an arbitrary
    /// start is far below the 0.25 % that six time constants alone would
    /// leave.
    static let stateHorizon: TimeInterval = 6 * dieSlowTimeConstant

    /// The machine's state at time `t`, integrated forward from a wall-anchored
    /// grid so consecutive reads are mutually consistent and any two processes
    /// asked at the same instant agree exactly.
    ///
    /// This is the same trick `actualRPM` already used to chase `targetRPM`,
    /// widened to carry the die with it: anchoring the grid to wall time
    /// rather than to when the caller happened to ask keeps the model a pure
    /// function of the clock, which is the house rule this file opens with.
    static func state(at t: TimeInterval) -> ThermalState {
        var gridTime = ((t - stateHorizon) / stateGridStep).rounded(.down) * stateGridStep

        // Seed at the starting instant's own equilibrium, with the fans where
        // that equilibrium would put them. A cold start would decay away
        // anyway, but seeding correctly makes the horizon honest.
        let seedRise = equilibriumRise(watts: power(at: gridTime), fanFraction: 0)
        var state = ThermalState(
            fastRise: seedRise,
            slowRise: seedRise,
            fanFraction: controlDemand(dieRise: seedRise)
        )

        while gridTime < t {
            let step = min(stateGridStep, t - gridTime)
            state = advance(state, from: gridTime, over: step)
            gridTime += step
        }
        return state
    }

    /// One integration step: the die chases the equilibrium the *current* fan
    /// speed allows, then the fans chase the demand the *new* die temperature
    /// creates. Both use the exact first-order-lag update, so the step size
    /// affects only how finely the drive signal is sampled, never the decay.
    private static func advance(
        _ state: ThermalState, from t: TimeInterval, over dt: TimeInterval
    ) -> ThermalState {
        let target = equilibriumRise(watts: power(at: t), fanFraction: state.fanFraction)
        var next = state
        next.fastRise = lagStep(state.fastRise, toward: target, over: dt, tau: dieFastTimeConstant)
        next.slowRise = lagStep(state.slowRise, toward: target, over: dt, tau: dieSlowTimeConstant)
        next.fanFraction = lagStep(
            state.fanFraction,
            toward: controlDemand(dieRise: next.dieRise),
            over: dt,
            tau: fanTimeConstant
        )
        return next
    }

    /// Exact first-order-lag update over `dt` for a constant target: the gap
    /// shrinks by a factor of e^(−dt/τ).
    private static func lagStep(
        _ value: Double, toward target: Double, over dt: TimeInterval, tau: TimeInterval
    ) -> Double {
        target + (value - target) * exp(-dt / tau)
    }

    // MARK: Sensors

    /// All six sensors at time `t`, each clamped to 20–110 °C.
    ///
    /// The die rise and the wander scale are hoisted: both are per-instant,
    /// not per-sensor.
    static func temperatures(at t: TimeInterval) -> [SensorReading] {
        let rise = state(at: t).dieRise
        let scale = wanderScale(at: t)
        return sensorSpecs.map { spec in
            SensorReading(
                key: spec.key,
                label: spec.label,
                celsius: temperature(of: spec, at: t, dieRise: rise, wanderScale: scale)
            )
        }
    }

    /// One sensor's temperature: idle base + its share of the machine's heat +
    /// slow sine wander (damped deep in steady stretches, see
    /// ``wanderScale(at:)``) + fast ripple, clamped to the model's 20–110 °C.
    static func temperature(
        of spec: SensorSpec, at t: TimeInterval, dieRise: Double, wanderScale: Double
    ) -> Double {
        let seed = seed(forKey: spec.key)
        let wanderPhase = 2 * .pi * unitNoise(seed, 10)
        let ripplePhase = 2 * .pi * unitNoise(seed, 11)
        let ripplePeriod = 11 + 12 * unitNoise(seed, 12) // 11–23 s, per sensor
        let wander = spec.wanderAmp * wanderScale
            * sin(2 * .pi * t / spec.wanderPeriod + wanderPhase)
            + 0.4 * sin(2 * .pi * t / ripplePeriod + ripplePhase)
        return (spec.idle + spec.riseShare * dieRise + wander).clamped(to: 20 ... 110)
    }

    // MARK: Fans

    /// What fraction of its range the auto controller wants, for a given die
    /// rise above resting.
    ///
    /// Reads the smooth integrated die, **not** the wandering sensor value.
    /// Wander is sensor noise of ±2.2 °C on a 35 °C control band; feeding it
    /// to the controller would make the fans chase a signal the real one
    /// filters out, and would put that noise inside the integration loop
    /// where it costs six trig evaluations per grid step.
    static func controlDemand(dieRise: Double) -> Double {
        smoothstep((controlSensor.idle + controlSensor.riseShare * dieRise - demandFloorCelsius)
            / (demandCeilingCelsius - demandFloorCelsius))
    }

    /// Instantaneous fan demand in 0…1: what fraction of the min→max range the
    /// auto controller wants, given how hot the machine is right now.
    static func demand(at t: TimeInterval) -> Double {
        controlDemand(dieRise: state(at: t).dieRise)
    }

    /// Demand filtered through the first-order lag — what fraction of the
    /// range the fan has physically reached. See ``state(at:)``.
    static func laggedDemand(at t: TimeInterval) -> Double {
        state(at: t).fanFraction
    }

    /// Both fans at time `t`, in `.system` mode (macOS in control), with
    /// target and actual RPM clamped to `[minRPM, maxRPM]`.
    ///
    /// One `state(at:)` call for both, rather than the two the separate
    /// `demand`/`laggedDemand` entry points would cost.
    static func fans(at t: TimeInterval) -> [Fan] {
        let now = state(at: t)
        let target = controlDemand(dieRise: now.dieRise)
        let lagged = now.fanFraction
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
