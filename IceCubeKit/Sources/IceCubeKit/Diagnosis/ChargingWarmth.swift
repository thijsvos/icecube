// ChargingWarmth.swift — the one cause of heat this app can name instead of rank.

import Foundation

/// Whether the warmth a person can feel right now is the battery charging.
///
/// **The gap this fills.** Ice Cube's model of heat is *heat means work*:
/// sensors get hot, fans spin, find the process. Charging breaks every link in
/// that chain. Charging a MacBook at 65–96 W dissipates roughly 6–10 W in the
/// cells and charging circuitry — a large flat component pressed against the
/// bottom case. The energy is real and none of it is compute, so the die stays
/// cool, the fans never respond, and `ThermalDiagnosis` correctly reports that
/// nothing is wrong while the owner's hand says otherwise. Measured on a
/// Mac14,9 charging: die 56 °C, both cells under 35 °C, no process above
/// 0.03 W, and a case that felt distinctly warm.
///
/// **Why it is warm at 35 °C.** Skin sits near 33 °C. Aluminium conducts well,
/// so a case at 35 °C gives the hand nowhere to shed heat — the hand simply
/// stops losing it, which the nervous system reads as warmth. "Warm to the
/// touch" and "hot for the hardware" are different scales: these cells are
/// 60 °C below the 95 °C limit ``SafetyMonitor`` polices them at.
///
/// **Why this may name its cause when `docs/DIAGNOSIS.md` forbids naming
/// causes.** That rule guards against *inferring* a cause from sensor patterns
/// — the app cannot see a blocked vent or dust on a heatsink, and its copy has
/// never claimed to. Charging is not inferred. It is read from IOKit, as a
/// fact, in the same dictionary `PowerSourceMonitor` already fetches. It is the
/// one cause the app does not have to guess at, which is precisely why it is
/// the one exception.
public enum ChargingWarmth: Sendable, Equatable {
    /// Say nothing. Either it is not charging, the case is not warm enough to
    /// be worth explaining, or the die is hot and charging is not the story.
    case silent
    /// The warmth is the battery taking charge.
    case warm(batteryCelsius: Double)

    /// Where charging warmth becomes worth explaining.
    ///
    /// First chosen at 32 °C from skin physiology alone — against ~33 °C skin a
    /// surface below about 30 °C reads as cool and by 32 °C it does not — with
    /// no idle baseline to check it against. Measured on a Mac14,9 the same
    /// day, that turned out to be exactly the wrong number:
    ///
    /// | State | Warmest cell |
    /// | --- | --- |
    /// | On battery, discharging | 24.4 °C |
    /// | Plugged in, charged, idle | **31.9 – 32.1 °C** |
    /// | Charging, 100 % (finishing) | 34.8 °C |
    /// | Charging, 55 % | 36.2 °C |
    ///
    /// The first row was taken at 26.4 W and the last at 11.1 W — more than
    /// twice the work, 12 °C cooler cells. Battery temperature tracks current
    /// through the cells, not workload, which is the premise this whole type
    /// rests on.
    ///
    /// A 32 °C onset sits *on* the idle baseline, so a Mac merely topping up
    /// from 99 % would trip it while dissipating almost nothing. 34 °C clears
    /// idle by two degrees and sits below every reading taken while genuinely
    /// charging, which is the gap the threshold is supposed to name.
    ///
    /// Skin physiology set the shape of the rule and hardware set the number.
    /// Both were needed: physiology alone put it a whole degree into the noise.
    public static let onsetCelsius: Double = 34

    /// Release below this, so the row cannot flicker around the onset. Same
    /// arm/re-arm shape as `AlertManager.evaluate`, with a smaller gap because
    /// these are small numbers moving slowly.
    ///
    /// 32 °C is the measured idle baseline: while charging continues the row
    /// holds until the cells fall back to where they sit when they are not.
    /// When charging *stops*, `isCharging` closes the row on its own and this
    /// threshold never comes into it.
    public static let releaseCelsius: Double = 32

    /// - Parameters:
    ///   - isCharging: read fresh from `PowerSourceObserving.isCharging`.
    ///     `.wall` is not a substitute — plugged in and full makes no heat.
    ///   - batteryCelsius: the warmest cell, or `nil` on a Mac with no battery.
    ///   - heat: the die verdict, so a genuinely hot chip suppresses this.
    ///   - wasWarm: whether this said `.warm` last time, which is the whole of
    ///     the hysteresis state. Held by the caller so this stays pure.
    public static func assess(
        isCharging: Bool,
        batteryCelsius: Double?,
        heat: ThermalDiagnosis.Heat,
        wasWarm: Bool
    ) -> ChargingWarmth {
        guard isCharging, let battery = batteryCelsius else { return .silent }

        // A hot die is a better answer than a warm battery, and offering both
        // would bury the one that matters. `.unknown` does not suppress: a Mac
        // with no die sensor cannot rule the chip in or out, and the battery
        // reading is still true.
        if case let .measured(_, _, band, _) = heat, band == .hot || band == .nearCeiling {
            return .silent
        }

        guard battery >= (wasWarm ? releaseCelsius : onsetCelsius) else { return .silent }
        return .warm(batteryCelsius: battery)
    }

    /// Whether this is saying anything, for the caller to feed back as
    /// `wasWarm` on the next pass.
    public var isWarm: Bool {
        if case .warm = self {
            true
        } else {
            false
        }
    }
}
