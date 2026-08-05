// Models.swift — the value types shared by app, helper, and tests: fans, sensors, config, presets.

import Foundation

/// The control state of one fan, as reported by (or requested from) the SMC.
///
/// On Apple Silicon the resting state is `.system` (mode 3): `thermalmonitord`
/// owns the fan. Treating `.system` as a failed `.auto` read-back is a classic
/// fan-app bug — model it explicitly.
public enum FanMode: UInt8, Sendable, Codable, Equatable {
    /// SMC automatic control (mode 0). What every revert path writes.
    case auto = 0
    /// Manually forced target RPM (mode 1). Only the helper daemon may enter this.
    case forced = 1
    /// macOS (`thermalmonitord`) is in control (mode 3) — the normal resting
    /// state on Apple Silicon; read-only, never written by us.
    case system = 3
}

public extension FanMode {
    /// The mode a raw SMC reading denotes, treating anything unrecognized as
    /// `.system`.
    ///
    /// SAFETY: `UInt8(someDouble)` **traps** on NaN, negatives, and anything
    /// over 255 — a `fatalError` in disguise, which daemon code paths forbid.
    /// The mode key's width is not ours to choose: it is whatever this Mac's
    /// firmware reports (`ui8`, `ui16`, `ui32`, …), and `SMCKeyCodec` only
    /// range-checks the `flt` case. A daemon crash here would skip the SIGTERM
    /// handler and strand the fans wherever they were, so an implausible
    /// reading must degrade to `.system`, never trap.
    init(smcValue: Double) {
        self = UInt8(exactly: smcValue.rounded(.towardZero))
            .flatMap(FanMode.init(rawValue:)) ?? .system
    }
}

/// One fan as read from the SMC.
public struct Fan: Identifiable, Sendable, Codable, Equatable {
    /// SMC fan index `i` in `F{i}…` keys (0-based).
    public let id: Int
    /// Human-readable name (from `F{i}ID` where available, e.g. "Left", "Right").
    public let name: String
    public let mode: FanMode
    /// Current measured speed (`F{i}Ac`), RPM.
    public let actualRPM: Double
    /// Current target speed (`F{i}Tg`), RPM.
    public let targetRPM: Double
    /// SMC-reported minimum (`F{i}Mn`), RPM.
    ///
    /// SAFETY: `minRPM`/`maxRPM` are *advisory* — Apple Silicon firmware does
    /// not enforce them and will accept 0 RPM. The helper daemon's clamp to
    /// `[minRPM, maxRPM]` is the real guard; it is not belt-and-braces.
    public let minRPM: Double
    /// SMC-reported maximum (`F{i}Mx`), RPM. See `minRPM` for why this matters.
    public let maxRPM: Double

    public init(
        id: Int,
        name: String,
        mode: FanMode,
        actualRPM: Double,
        targetRPM: Double,
        minRPM: Double,
        maxRPM: Double
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// Whether this fan's `[minRPM, maxRPM]` range read well enough to drive it.
    ///
    /// SAFETY: `Mn` and `Mx` are read with independent `try?`s that each fall
    /// back to 0 ("degrade per-key rather than losing the whole fan"), so three
    /// bad shapes are all modelled outcomes: both zero, inverted, and — the one
    /// that used to slip through — **only `Mn` failed**. The old guards all
    /// tested `maxRPM > minRPM`, which is *true* for `(0, 6800)`: the clamp range
    /// then became `0...6800`, i.e. no floor at all, and a commanded 0 RPM
    /// reached the wire. Requiring a positive floor is what closes that.
    ///
    /// A fan that fails this must be **skipped**, never driven.
    public var hasUsableRange: Bool {
        minRPM > 0 && maxRPM > minRPM
    }
}

/// One temperature sensor reading.
public struct SensorReading: Identifiable, Sendable, Codable, Equatable {
    /// The SMC key, e.g. `"Tp01"` — unique per sensor, stable across reads.
    public let key: String
    /// Display label, e.g. "CPU P-core 1". Falls back to the key on unknown models.
    public let label: String
    /// Temperature in degrees Celsius.
    public let celsius: Double

    public var id: String {
        key
    }

    public init(key: String, label: String, celsius: Double) {
        self.key = key
        self.label = label
        self.celsius = celsius
    }

    /// Whether this is a die-class (CPU/GPU silicon) sensor — the input the
    /// fan curve follows and the safety ceiling classifies. See
    /// ``SMCKeyMaps/isDieKey(_:)`` (the single source of truth).
    public var isDieSensor: Bool {
        SMCKeyMaps.isDieKey(key)
    }

    /// What this sensor measures. See ``SMCKeyMaps/classify(_:)``.
    public var sensorClass: SMCKeyMaps.SensorClass {
        SMCKeyMaps.classify(key)
    }
}

public extension Collection<SensorReading> {
    /// The hottest die-class reading — the fan curve's input and the
    /// guardian's escalation trigger. `nil` when no die sensor is present.
    ///
    /// Extracted because this exact chain was inlined three times, twice
    /// inside the daemon, and the two daemon copies had already diverged in
    /// their nil handling (`guard let` in the curve loop, `?? 0` in the
    /// guardian). `lazy` avoids two intermediate arrays on a path that runs
    /// every 2 s in the daemon and every second in the app.
    var hottestDieCelsius: Double? {
        lazy.filter(\.isDieSensor).map(\.celsius).max()
    }

    /// The hottest reading in `sensorClass`, or `nil` if none is present.
    func hottestCelsius(in sensorClass: SMCKeyMaps.SensorClass) -> Double? {
        lazy.filter { $0.sensorClass == sensorClass }.map(\.celsius).max()
    }
}

/// One timestamped reading of all fans and sensors — what polling publishes.
public struct SMCSnapshot: Sendable, Codable, Equatable {
    public let date: Date
    public let fans: [Fan]
    public let temperatures: [SensorReading]
    /// Total **system** power in watts, or `nil` on a Mac with no usable key.
    ///
    /// `PSTR`, which docs/SMC-KEYS.md measured as system total — not the SoC
    /// package alone. The distinction matters wherever this is divided into a
    /// die temperature; see docs/THERMAL.md.
    ///
    /// Optional and defaulted so an older encoded snapshot still decodes, and
    /// because `nil` is a real answer rather than a failure — a Mac without
    /// `PSTR`/`PDTR` has no wattage to show, and the app omits the figure rather
    /// than substituting a guess.
    public let power: Double?

    public init(
        date: Date,
        fans: [Fan],
        temperatures: [SensorReading],
        power: Double? = nil
    ) {
        self.date = date
        self.fans = fans
        self.temperatures = temperatures
        self.power = power
    }

    /// The hottest sensor right now — drives the menu bar readout and badge.
    public var hottest: SensorReading? {
        temperatures.max { $0.celsius < $1.celsius }
    }

    /// The hottest sensor **with flicker hysteresis** for UI labels.
    ///
    /// Near-equal cores trade the top spot every tick, which makes a label
    /// that names the hottest sensor rewrite itself constantly. This variant
    /// keeps the previously shown sensor in the title as long as it stays
    /// within `hysteresis` °C of the true maximum — the displayed *value* is
    /// still that sensor's current reading, so the UI never lies by more
    /// than the hysteresis band.
    public func hottest(stickingTo previousKey: String?, hysteresis: Double = 1.0) -> SensorReading? {
        guard let top = hottest else { return nil }
        guard let previousKey,
              let previous = temperatures.first(where: { $0.key == previousKey }),
              top.celsius - previous.celsius < hysteresis
        else {
            return top
        }
        return previous
    }
}
