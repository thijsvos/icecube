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

    public init(date: Date, fans: [Fan], temperatures: [SensorReading]) {
        self.date = date
        self.fans = fans
        self.temperatures = temperatures
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

/// The control configuration the app sends to the helper daemon over XPC (Phase 3+).
///
/// Phase 0 defines only the shape the UI needs; curves arrive in Phase 4.
/// SAFETY: this is a *request* — the daemon clamps, debounces, and may refuse.
/// Manual mode is always heartbeat-watchdogged and never persists app-less;
/// only curve mode may keep running after the app quits.
public struct FanConfig: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable {
        /// Give control back to macOS. A fresh install is always `.auto`.
        case auto
        /// Fixed per-fan targets. Watchdogged: no app heartbeat for 15 s → auto.
        case manual
        /// Temperature→RPM curve, run daemon-side (Phase 4).
        case curve
    }

    public var mode: Mode
    /// Fan id → requested target RPM; used only when `mode == .manual`.
    /// Clamped daemon-side to each fan's `[minRPM, maxRPM]`.
    public var manualTargets: [Int: Double]
    /// Keep the curve running when the app quits. Curve mode only — ignored
    /// (treated as false) in manual mode.
    public var persistsWithoutApp: Bool
    /// The curve applied to every fan without a per-fan override (Phase 4).
    public var sharedCurve: FanCurve?
    /// Per-fan curve overrides, fan id → curve.
    public var perFanCurves: [Int: FanCurve]
    /// Input deadband for the curve follower, °C.
    public var hysteresisCelsius: Double
    /// Max output change per daemon tick, fraction of fan range.
    public var rampPerTick: Double

    public init(
        mode: Mode,
        manualTargets: [Int: Double] = [:],
        persistsWithoutApp: Bool = false,
        sharedCurve: FanCurve? = nil,
        perFanCurves: [Int: FanCurve] = [:],
        hysteresisCelsius: Double = 4,
        rampPerTick: Double = 0.1
    ) {
        self.mode = mode
        self.manualTargets = manualTargets
        self.persistsWithoutApp = persistsWithoutApp
        self.sharedCurve = sharedCurve
        self.perFanCurves = perFanCurves
        self.hysteresisCelsius = hysteresisCelsius
        self.rampPerTick = rampPerTick
    }

    /// Back-compatible decoding: configs written before Phase 4 (no curve
    /// fields) must keep decoding — this is also the daemon's persistence
    /// format, and a failed decode at boot silently costs the boot promise.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        manualTargets = try c.decodeIfPresent([Int: Double].self, forKey: .manualTargets) ?? [:]
        persistsWithoutApp = try c.decodeIfPresent(Bool.self, forKey: .persistsWithoutApp) ?? false
        sharedCurve = try c.decodeIfPresent(FanCurve.self, forKey: .sharedCurve)
        perFanCurves = try c.decodeIfPresent([Int: FanCurve].self, forKey: .perFanCurves) ?? [:]
        hysteresisCelsius = try c.decodeIfPresent(Double.self, forKey: .hysteresisCelsius) ?? 4
        rampPerTick = try c.decodeIfPresent(Double.self, forKey: .rampPerTick) ?? 0.1
    }

    /// The curve governing `fanID`: per-fan override, else the shared curve.
    public func curve(for fanID: Int) -> FanCurve? {
        perFanCurves[fanID] ?? sharedCurve
    }

    /// A curve config is executable when every fan can resolve a usable curve
    /// (per-fan overrides may exist, but the shared curve is the safety net).
    public var isUsableCurveConfig: Bool {
        mode == .curve && (sharedCurve?.isUsable ?? false)
    }

    /// The safe default: everything back to macOS control.
    public static let auto = FanConfig(mode: .auto)

    /// A ready-to-apply curve config.
    public static func curve(
        _ curve: FanCurve, persists: Bool = false
    ) -> FanConfig {
        FanConfig(mode: .curve, persistsWithoutApp: persists, sharedCurve: curve)
    }
}

/// A named, user-selectable fan configuration.
public struct Preset: Identifiable, Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case auto, quiet, balanced, cold, max, custom
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var config: FanConfig

    public init(id: UUID = UUID(), name: String, kind: Kind, config: FanConfig) {
        self.id = id
        self.name = name
        self.kind = kind
        self.config = config
    }
}
