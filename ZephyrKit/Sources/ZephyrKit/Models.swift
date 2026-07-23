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

    public init(mode: Mode, manualTargets: [Int: Double] = [:], persistsWithoutApp: Bool = false) {
        self.mode = mode
        self.manualTargets = manualTargets
        self.persistsWithoutApp = persistsWithoutApp
    }

    /// The safe default: everything back to macOS control.
    public static let auto = FanConfig(mode: .auto)
}

/// A named, user-selectable fan configuration.
public struct Preset: Identifiable, Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case auto, quiet, balanced, max, custom
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
