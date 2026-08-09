// CoolingEfficiency.swift — how many degrees this Mac pays per watt, and when that number is safe to believe.

import Foundation

/// The machine's **thermal resistance**: `R = (T_die − T_ambient) / P`, in °C per watt.
///
/// This is the quantity heatsinks are specified in, and it is the one number in
/// this app that describes the *cooling system* rather than the workload. That
/// distinction is the whole point:
///
/// - Raw temperature is not comparable to itself over time. 95 °C means "fine"
///   during a compile and "something is wrong" at idle, and Ice Cube draws both
///   identically today.
/// - `R` **is** comparable, because dividing by power removes the load. A Mac
///   idling and a Mac compiling should report similar `R` at the same fan speed.
/// - `R` falls as the fans spin up, which makes it a measurement of exactly what
///   the noise is buying — the trade this entire app exists to manage.
/// - `R` rises as a machine ages. Dust, dried paste and a failing bearing all
///   show up here before they show up anywhere else.
///
/// **The arithmetic is trivial; the discipline is the feature.** A quotient of
/// two noisy measurements is easy to compute and easy to get wrong, so this type
/// refuses to answer more often than it answers. See ``resistance(dieCelsius:ambientCelsius:watts:)``
/// for the three ways it returns `nil`, and ``isSettled(_:)`` for the fourth.
///
/// Full reasoning, measured constants and the interpretation guide live in
/// `docs/THERMAL.md`.
public enum CoolingEfficiency {
    // MARK: - Constants, and the measurements that set them

    /// Below this many watts, `R` is not reported.
    ///
    /// `R` is a quotient, so as `P → 0` the noise in `ΔT` is amplified without
    /// bound: at 4 W a ±1 °C sensor wobble moves `R` by ±0.25 °C/W, which is
    /// larger than the difference between a clean Mac and a dusty one. The floor
    /// is above the idle draw `docs/SMC-KEYS.md` measured on Mac14,9
    /// (`PSTR` 19.6 W idle), so a genuinely idle Mac reports a value — the floor
    /// exists for the pathological low end, not to silence normal use.
    public static let minimumWatts: Double = 5

    /// `R` is only meaningful at steady state, and this is how long "steady" has
    /// to last.
    ///
    /// Silicon has thermal mass. After a load step the die keeps *absorbing*
    /// heat, so `ΔT` lags `P` and the instantaneous quotient describes neither
    /// the old state nor the new one. Twenty seconds is ten polls at the app's
    /// default 1 Hz cadence — long enough to outlast the ramp, short enough that
    /// an ordinary idle desktop settles within it.
    public static let settleWindow: TimeInterval = 20

    /// How much power may drift within the window and still count as settled.
    ///
    /// Expressed as a fraction of the mean rather than an absolute wattage,
    /// because 2 W of wobble is noise at 50 W and a doubling at 4 W.
    public static let powerTolerance: Double = 0.15

    /// How much the die may drift within the window and still count as settled.
    ///
    /// One degree is roughly the quantisation of the SMC's own reporting, so a
    /// tighter bound would mean never settling.
    public static let temperatureToleranceCelsius: Double = 1.5

    // MARK: - The measurement

    /// One tick's worth of the three quantities `R` needs.
    public struct Sample: Sendable, Equatable {
        public let date: Date
        public let dieCelsius: Double
        public let ambientCelsius: Double
        public let watts: Double

        public init(date: Date, dieCelsius: Double, ambientCelsius: Double, watts: Double) {
            self.date = date
            self.dieCelsius = dieCelsius
            self.ambientCelsius = ambientCelsius
            self.watts = watts
        }
    }

    /// `R` for one instant, or `nil` when the inputs cannot support an honest
    /// answer.
    ///
    /// Returns `nil` in three cases, each deliberate:
    ///
    /// 1. **Any input is not finite.** A failed sensor read must not become a
    ///    number.
    /// 2. **Power is below ``minimumWatts``.** See that constant.
    /// 3. **The die is at or below ambient.** Physically this means the machine
    ///    is dissipating nothing measurable, and arithmetically it would yield a
    ///    zero or negative resistance, which is not a thing. It happens for real
    ///    at cold boot, when the die and the airflow sensors agree.
    ///
    /// Note what is *not* checked here: whether the reading is settled. That is
    /// a property of a window, not an instant, and belongs to ``isSettled(_:)``.
    /// Callers must ask both.
    public static func resistance(
        dieCelsius: Double,
        ambientCelsius: Double,
        watts: Double
    ) -> Double? {
        guard dieCelsius.isFinite, ambientCelsius.isFinite, watts.isFinite else { return nil }
        guard watts >= minimumWatts else { return nil }
        let delta = dieCelsius - ambientCelsius
        guard delta > 0 else { return nil }
        return delta / watts
    }

    /// The shortest trailing run of samples spanning at least ``settleWindow``,
    /// or `nil` when the series is too short to contain one.
    ///
    /// Settledness is judged on this suffix, **not** on everything a caller
    /// happens to remember. The rule is "steady for the last 20 seconds", and
    /// a buffer that remembers more than 20 seconds must not quietly raise
    /// the bar. It did exactly that until 2026-08-08: ``Tracker`` retains
    /// twice the window (so a full window survives any poll cadence), the
    /// whole buffer was evaluated, and every documented "20 seconds" was in
    /// truth ~40 — enough that the simulated thermal model settled on 0.9 %
    /// of its ticks.
    private static func settleSuffix(_ samples: [Sample]) -> ArraySlice<Sample>? {
        guard let last = samples.last else { return nil }
        let windowStart = last.date.addingTimeInterval(-settleWindow)
        // Walk back from the end to the first sample at or before the window
        // boundary, so the suffix is the shortest that still spans the full
        // window at any poll cadence.
        var start = samples.count - 1
        while start > 0, samples[start].date > windowStart {
            start -= 1
        }
        guard samples[start].date <= windowStart else { return nil }
        return samples[start...]
    }

    /// Whether the trailing ``settleWindow`` of a series is stable enough for
    /// ``resistance(dieCelsius:ambientCelsius:watts:)`` to describe the
    /// cooling rather than a transient.
    ///
    /// Requires all four, over that trailing window:
    /// - the window spans at least ``settleWindow`` seconds,
    /// - every sample is above ``minimumWatts``,
    /// - power stays within ``powerTolerance`` of its mean,
    /// - the die stays within ``temperatureToleranceCelsius`` of its mean.
    ///
    /// A disturbance older than the window does not veto a machine that has
    /// held steady for the full window since — that is what "the last
    /// 20 seconds" means.
    ///
    /// Deliberately conservative in one direction only. A false "unsettled"
    /// costs a dash on screen; a false "settled" publishes a number that
    /// describes nothing, and a user cannot tell the difference by looking.
    public static func isSettled(_ samples: [Sample]) -> Bool {
        guard let window = settleSuffix(samples) else { return false }
        guard window.allSatisfy({ $0.watts.isFinite && $0.dieCelsius.isFinite }) else { return false }
        guard window.allSatisfy({ $0.watts >= minimumWatts }) else { return false }

        let meanWatts = window.reduce(0) { $0 + $1.watts } / Double(window.count)
        guard meanWatts > 0 else { return false }
        let powerDrift = window.allSatisfy { abs($0.watts - meanWatts) / meanWatts <= powerTolerance }
        guard powerDrift else { return false }

        let meanDie = window.reduce(0) { $0 + $1.dieCelsius } / Double(window.count)
        return window.allSatisfy { abs($0.dieCelsius - meanDie) <= temperatureToleranceCelsius }
    }

    /// The trailing window's `R`, or `nil` if it is not settled.
    ///
    /// Averages the inputs before dividing rather than averaging the per-sample
    /// quotients. The two differ, and this order is the correct one: `R` is
    /// defined on steady-state means, and averaging quotients would let one
    /// low-power sample dominate the result.
    ///
    /// Averages the **same trailing window** ``isSettled(_:)`` judged. Anything
    /// older was excused by the settle rule and must not leak into the number.
    public static func settledResistance(_ samples: [Sample]) -> Double? {
        guard isSettled(samples), let window = settleSuffix(samples) else { return nil }
        let count = Double(window.count)
        let die = window.reduce(0) { $0 + $1.dieCelsius } / count
        let ambient = window.reduce(0) { $0 + $1.ambientCelsius } / count
        let watts = window.reduce(0) { $0 + $1.watts } / count
        return resistance(dieCelsius: die, ambientCelsius: ambient, watts: watts)
    }

    /// The ambient reference: the coolest of the airflow sensors.
    ///
    /// **This is not room temperature.** `TaLP`/`TaRF` sit inside the airflow
    /// path, downstream of a warm machine, so they read several degrees above
    /// the room. That is acceptable — and in one way preferable — because `R`
    /// here is only ever compared against *the same machine's own history*, and
    /// a consistent reference is what that requires.
    ///
    /// The consequence has to be said out loud wherever the number is shown:
    /// **this `R` is not comparable between two different Macs.**
    ///
    /// Coolest rather than mean, because the sensor least heated by the SoC is
    /// the closest available proxy for intake air.
    public static func ambient(from temperatures: [SensorReading]) -> Double? {
        let airflow = temperatures.filter { SMCKeyMaps.isAirflowKey($0.key) }
        guard !airflow.isEmpty else { return nil }
        return airflow.map(\.celsius).min()
    }

    /// Turns a stream of snapshots into a settled reading, or nothing.
    ///
    /// Retains twice the ``settleWindow`` of samples — enough that a full
    /// window survives any poll cadence — while settledness itself is judged
    /// on the trailing window only. This runs at the polling cadence for the
    /// life of the app, so it must not grow.
    ///
    /// A snapshot missing any of the three inputs (no power key, no airflow
    /// sensor, a failed read) **clears** the window rather than being skipped.
    /// Skipping would silently stitch together two sides of a gap and call the
    /// result steady, which is exactly the lie the settle rule exists to
    /// prevent.
    public struct Tracker: Sendable {
        private var samples: [Sample] = []

        public init() {}

        /// The window's resistance, or `nil` while it is unsettled.
        public var resistance: Double? {
            CoolingEfficiency.settledResistance(samples)
        }

        /// Whether a value is currently available — the UI shows `—` when false.
        public var isSettled: Bool {
            CoolingEfficiency.isSettled(samples)
        }

        public mutating func ingest(_ snapshot: SMCSnapshot) {
            guard
                let watts = snapshot.power,
                let ambient = CoolingEfficiency.ambient(from: snapshot.temperatures),
                let die = snapshot.temperatures.filter(\.sensorClass.isDie).map(\.celsius).max()
            else {
                samples.removeAll()
                return
            }
            samples.append(
                Sample(date: snapshot.date, dieCelsius: die, ambientCelsius: ambient, watts: watts)
            )
            // Trim to twice the settle window: enough to keep a full window
            // after any plausible cadence, bounded so uptime cannot grow it.
            //
            // A sample dated *after* the snapshot is a clock that has stepped
            // backwards. Left in place it sits at the end of the buffer where
            // an age-only trim can never reach it, the window's span reads
            // negative forever, and `R` shows `—` for the rest of the process
            // with no error and no log line. Dropped instead: the step already
            // broke the window's continuity, and re-earning it costs the same
            // 20 seconds any other gap costs.
            let cutoff = snapshot.date.addingTimeInterval(-settleWindow * 2)
            samples.removeAll { $0.date < cutoff || $0.date > snapshot.date }
        }
    }
}
