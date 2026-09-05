// CurveDerivationCopy.swift — the words for a curve the app drew, which must never sound like advice it can't back.

import Foundation

/// Every word the curve editor's derivation panel says, as a pure function of
/// the verdict.
///
/// Separated from layout for the reason ``DiagnosisCopy`` and ``ForecastCopy``
/// already give — it is testable here and not inside a `View` body — and it
/// carries a version of the obligation ``ForecastCopy`` describes, sharpened.
///
/// ## What this copy has to get right
///
/// The forecast row *reports* a projection and the user reads it. This panel
/// *hands over a curve* and the user applies it to their fans. The wording has
/// to make three things impossible to miss:
///
/// - **It is built from this Mac's own readings**, so the sentence says how
///   many and over what — a curve from 40 readings and a curve from 1,400 are
///   not the same claim, and only one of them is worth trusting over a preset.
/// - **A target the machine cannot reach is a finding, not a failure.** When
///   full fans still land above the request, the panel says what the machine
///   *can* hold and does not quietly hand over a curve that misses.
/// - **A refusal names the missing input**, so an empty panel is legibly
///   waiting rather than looking broken.
///
/// Every temperature goes through ``TemperatureStyle``: there is no bare °C in
/// this file, because a reader in Fahrenheit must get the same sentence.
public enum CurveDerivationCopy {
    /// One rendered verdict: a headline, the sentence under it, and whether it
    /// should be drawn as a caution.
    public struct Summary: Sendable, Equatable {
        public let headline: String
        public let detail: String
        /// True only when the machine cannot hold what was asked. Not for a
        /// refusal — a refusal is the feature waiting for evidence, which is
        /// the ordinary state of a fresh install and not a problem.
        public let isCaution: Bool
    }

    public static func summary(
        _ verdict: CurveDerivation.Verdict,
        style: TemperatureStyle
    ) -> Summary {
        switch verdict {
        case let .derived(derivation):
            derived(derivation, style: style)
        case let .unavailable(gap):
            unavailable(gap)
        }
    }

    // MARK: - A curve

    private static func derived(
        _ derivation: CurveDerivation.Derivation,
        style: TemperatureStyle
    ) -> Summary {
        let evidence = "Built from \(derivation.records) readings at "
            + "\(derivation.bandsUsed) fan speeds, over "
            + "\(wattsRange(derivation.wattsRange)) of draw."

        guard let shortfall = derivation.shortfall else {
            return Summary(
                headline: "Holds \(style.reading(derivation.targetCelsius))",
                detail: evidence + " The quietest fan speeds your Mac has been "
                    + "measured at that keep it there.",
                isCaution: false
            )
        }
        // The finding worth the whole feature: the machine's actual limit,
        // named. Said as what it *does* hold, because "cannot hold 85°" alone
        // reads as a failure of the app rather than a fact about the hardware.
        return Summary(
            headline: "Holds \(style.reading(shortfall.settlesAtCelsius)), not "
                + "\(style.reading(derivation.targetCelsius))",
            detail: evidence + " Even at the fastest fan speed your Mac has "
                + "been measured at, \(watts(shortfall.watts)) settles at "
                + "\(style.reading(shortfall.settlesAtCelsius)). This curve holds "
                + "that. Nothing on this Mac holds "
                + "\(style.reading(derivation.targetCelsius)) under that load.",
            isCaution: true
        )
    }

    // MARK: - No curve

    private static func unavailable(_ gap: CurveDerivation.Gap) -> Summary {
        switch gap {
        case let .tooFewBands(measured, need) where measured == 0:
            Summary(
                headline: "Nothing measured yet",
                detail: "Ice Cube fits a cooling law from readings taken while "
                    + "your Mac sits at a steady load. It needs \(need) different "
                    + "fan speeds before it can say what one buys over another — "
                    + "about a week of ordinary use.",
                isCaution: false
            )
        case let .tooFewBands(measured, need):
            Summary(
                headline: "One fan speed is not a comparison",
                detail: "Your Mac has been measured at \(measured) fan speed so far, "
                    + "and \(need) are needed. Until it has run at a second one "
                    + "there is nothing to compare — what a faster fan buys on "
                    + "this machine is exactly the thing that has not been seen yet.",
                isCaution: false
            )
        case .noLoadCovered:
            Summary(
                headline: "Not enough range in the readings",
                detail: "The readings so far all sit at one load. A cooling law "
                    + "needs to see your Mac working at different intensities "
                    + "before it can tell load and fan speed apart.",
                isCaution: false
            )
        }
    }

    // MARK: - Units

    /// Watts, to whole numbers.
    ///
    /// No decimal: `PSTR` is a whole-system reading whose burst noise
    /// `docs/SMC-KEYS.md` measured at ±15 W. A tenth of a watt beside that is
    /// precision theatre.
    private static func watts(_ value: Double) -> String {
        "\(Int(value.rounded())) W"
    }

    /// A span of draw, carrying the unit once — the shape
    /// ``TemperatureStyle/range(_:_:)`` uses for the same reason.
    private static func wattsRange(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound.rounded()))–\(watts(range.upperBound))"
    }
}
