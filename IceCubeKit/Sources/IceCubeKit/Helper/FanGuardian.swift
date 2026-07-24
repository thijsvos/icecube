// FanGuardian.swift — decides when Ice Cube must cool the Mac itself under auto (pure, no hardware).

import Foundation

/// FIELD FINDING (2026-07-23, Mac14,9 / macOS 26.4.1): after any fan app
/// touches the SMC, macOS's own fan management does NOT reliably resume — we
/// observed die temperatures climbing through 78…92 °C with the fans parked and
/// macOS never intervening, mode 3 notwithstanding. "Hand back and hope" is
/// therefore not a safety strategy. Whenever the config is auto and the machine
/// is warm while nothing spins, the daemon drives the fans itself along a
/// built-in curve (gentle at 70 °C, maximum by 95 °C) and releases once the die
/// is truly cool.
///
/// Pure decision engine, shaped exactly like ``SafetyMonitor``: readings in, an
/// action out, no I/O and no clock — so every rung of the escalation ladder is
/// unit-testable without a hot Mac. ``DaemonCore`` keeps the hardware writes.
public struct FanGuardian: Sendable {
    /// What the daemon should do this tick. The daemon performs the I/O; every
    /// state decision has already been made here.
    public enum Action: Sendable, Equatable {
        /// Nothing to do.
        case idle
        /// Drive (or re-aim) the fans along the built-in curve.
        case engage(targets: [Int: Double], dieCelsius: Double)
        /// Cooled down: hand the fans back and reset the SMC connection.
        case release(dieCelsius: Double)
        /// Gentle ladder stage 1: re-park these fans and hand control back.
        case reparkOrphans([Fan])
        /// Gentle ladder stage 2: the system never resumed — hold the floor.
        case holdAtFloor(targets: [Int: Double])
    }

    /// Tunables, overridable in tests only — release code uses the defaults.
    public struct Limits: Sendable {
        /// Guardian considers engaging at this die temperature…
        public var engageCelsius: Double = 75
        /// …and releases below this one (wide hysteresis, no flapping).
        public var releaseCelsius: Double = 65
        /// Consecutive warm-and-nobody-cooling ticks required to engage.
        public var engageDebounceTicks = 2
        /// Consecutive ticks with a cool orphaned fan before the ladder starts.
        public var orphanDebounceTicks = 3
        /// A fan counts as "not cooling" when it trails demand by this much.
        public var coolingSlackRPM: Double = 400
        /// Below this RPM a fan is considered stopped.
        public var stoppedRPM: Double = 100

        public init() {}
    }

    private let limits: Limits

    /// Everything the guardian remembers, in one value.
    ///
    /// Grouped deliberately: these counters used to be five loose properties on
    /// ``DaemonCore``, and each mode transition reset a different subset — a
    /// revert cleared the engage debounce but left the orphan-ladder counters
    /// stale, so the next orphaned tick could skip the gentle "re-park and hand
    /// back" stage and jump straight to holding the fans. One value means one
    /// reset that cannot be partial.
    private struct State: Sendable, Equatable {
        var isActive = false
        var targets: [Int: Double] = [:]
        /// Consecutive warm-and-nobody-cooling ticks (engage debounce).
        var warmTicks = 0
        /// Consecutive ticks with a cool orphaned fan (ladder debounce).
        var orphanTicks = 0
        /// Escalation stage of the gentle ladder.
        var recoveryStage = 0
    }

    private var state = State()

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// True while the guardian curve is driving the fans — mirrored into
    /// `HelperStatus.guardianActive` so the UI can say "Automatic · cooling".
    public var isActive: Bool {
        state.isActive
    }

    /// Forgets every counter. Called on any mode transition, so a stale
    /// debounce can never leak across a revert or a new config.
    public mutating func reset() {
        state = State()
    }

    /// Evaluates one auto-mode tick.
    ///
    /// - Parameters:
    ///   - fans: this tick's fan readings.
    ///   - dieCelsius: the hottest die-class sensor, or 0 if none could be read.
    public mutating func evaluate(fans: [Fan], dieCelsius: Double) -> Action {
        if state.isActive {
            guard dieCelsius >= limits.releaseCelsius else {
                state.isActive = false
                state.targets = [:]
                return .release(dieCelsius: dieCelsius)
            }
            let targets = Self.curveTargets(for: fans, dieCelsius: dieCelsius)
            guard targets != state.targets else { return .idle }
            state.targets = targets
            return .engage(targets: targets, dieCelsius: dieCelsius)
        }

        // Engage when warm and nothing is effectively cooling.
        let demand = Self.curveTargets(for: fans, dieCelsius: dieCelsius)
        let nobodyCooling = fans.contains { fan in
            fan.mode != .forced && fan.actualRPM + limits.coolingSlackRPM < (demand[fan.id] ?? 0)
        }
        if dieCelsius >= limits.engageCelsius, nobodyCooling {
            state.warmTicks += 1
            guard state.warmTicks >= limits.engageDebounceTicks else { return .idle }
            state.warmTicks = 0
            state.isActive = true
            state.targets = demand
            return .engage(targets: demand, dieCelsius: dieCelsius)
        }
        state.warmTicks = 0

        // Cool orphan: mode 0 with stopped fans — always wrong, never urgent.
        let orphaned = fans.filter {
            $0.actualRPM < limits.stoppedRPM && $0.minRPM > 0 && $0.mode == .auto
        }
        guard !orphaned.isEmpty else {
            state.orphanTicks = 0
            state.recoveryStage = 0
            return .idle
        }
        state.orphanTicks += 1
        guard state.orphanTicks >= limits.orphanDebounceTicks else { return .idle }
        state.orphanTicks = 0
        state.recoveryStage += 1
        if state.recoveryStage == 1 {
            return .reparkOrphans(orphaned)
        }
        return .holdAtFloor(
            targets: Dictionary(uniqueKeysWithValues: fans.lazy
                .filter { $0.minRPM > 0 }
                .map { ($0.id, $0.minRPM) })
        )
    }

    /// The built-in guardian curve: 0 below 70 °C, then 20 %…100 % of each
    /// fan's range linearly from 70 to 95 °C. Quantized to 100 RPM steps so
    /// small temperature wiggles don't cause write churn.
    ///
    /// Routed through ``FanWriteSequencer/quantizedTarget(fraction:fan:step:)``
    /// rather than repeating the arithmetic: that helper also clamps back into
    /// `[Mn, Mx]`, which matters because quantizing can round a target *below*
    /// the SMC-reported minimum (on Mac14,9, `Mn` 2317 → 2300). Without the
    /// clamp the guardian would remember a target it never actually wrote.
    /// SAFETY: a fan whose `[Mn, Mx]` range didn't read (both 0) is skipped, not
    /// driven — mapping any fraction into a 0…0 range commands 0 RPM, which is
    /// forbidden everywhere in Ice Cube. ``DaemonCore``'s curve loop has always
    /// guarded this; the guardian's hand-rolled copy of the mapping did not.
    public static func curveTargets(for fans: [Fan], dieCelsius: Double) -> [Int: Double] {
        let fraction: Double = if dieCelsius <= 70 {
            0
        } else {
            min(1.0, 0.2 + 0.8 * (dieCelsius - 70.0) / 25.0)
        }
        return Dictionary(uniqueKeysWithValues: fans.lazy
            .filter { $0.maxRPM > $0.minRPM }
            .map { fan in
                (fan.id, FanWriteSequencer.quantizedTarget(fraction: fraction, fan: fan, step: 100))
            })
    }
}
