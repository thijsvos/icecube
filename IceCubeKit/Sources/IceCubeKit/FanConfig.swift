// FanConfig.swift — the fan-control intent: the XPC request, and the daemon's on-disk persistence format.

import Foundation

/// The control configuration the app sends to the helper daemon over XPC (Phase 3+).
///
/// Phase 0 defines only the shape the UI needs; curves arrive in Phase 4.
/// SAFETY: this is a *request* — the daemon clamps, debounces, and may refuse.
/// Manual mode is always heartbeat-watchdogged and never persists app-less;
/// only curve mode may keep running after the app quits.
public struct FanConfig: Sendable, Codable, Equatable {
    /// What the daemon is enforcing. Note `.auto` is a resting state rather
    /// than a choice — no UI can select it since the macOS preset was removed.
    public enum Mode: String, Sendable, Codable {
        /// Nobody is driving the fans from a user choice: the daemon's state
        /// before the first config arrives, and what every revert lands in.
        ///
        /// NOT user-selectable since 2026-07-26 — there is no longer a preset
        /// for it. It remains the daemon's resting state and the target of
        /// every safety revert, and while it is in force the guardian still
        /// keeps the fans off a standstill on a warm machine. To genuinely
        /// return the fans to macOS the daemon has to go: Settings ->
        /// "Turn Off Fan Control".
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
