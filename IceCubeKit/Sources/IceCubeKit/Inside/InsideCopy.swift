// InsideCopy.swift — the sentence under the cooling schematic, so the words are tested too.

import Foundation

/// What the schematic says in words.
///
/// Separated from the drawing for the reason ``DiagnosisCopy`` exists: the
/// sentence is the part a user actually acts on, and a sentence buried in a
/// `View` body is a sentence no test can read. Every state produces a distinct
/// headline, asserted exhaustively over ``HeatFlow/State/allCases``.
public enum InsideCopy {
    /// The bold line: what is happening, in five words or so.
    public static func headline(_ state: HeatFlow.State) -> String {
        switch state {
        case .warmingUp: "Warming up"
        case .coolAndQuiet: "Cool and quiet"
        case .working: "Working, and being cooled"
        case .hotAndUncooled: "Hot, and nothing is cooling it"
        }
    }

    /// The quiet line under it: the evidence, in the units it was measured in.
    ///
    /// `gradient` is how far the hottest silicon sits above the incoming air.
    /// It is stated as a plain figure and never as a verdict — the number that
    /// carries a claim about *cooling* is `R`, which needs watts and a settle
    /// rule, and that lives in the Cooling History window.
    public static func detail(_ state: HeatFlow.State, gradient: Double?, flow: Double?) -> String {
        let rise = gradient.map { "\(Int($0.rounded()))° above the air coming in" }
        switch state {
        case .warmingUp:
            return "The silicon is no warmer than the air around it yet."
        case .coolAndQuiet:
            return rise.map { "\($0). Nothing much is happening." }
                ?? "Nothing much is happening."
        case .working:
            guard let rise else { return "The fans are keeping up." }
            guard let flow else { return "\(rise), cooled without fans." }
            return "\(rise), and the fans are at \(Int((flow * 100).rounded()))% of their range."
        case .hotAndUncooled:
            return rise.map { "\($0), and the fans are barely turning." }
                ?? "The fans are barely turning."
        }
    }

    /// The standing caveat, shown once in the window rather than on every tick.
    ///
    /// Two claims are being fenced off here. The layout is a schematic — Ice
    /// Cube does not know where a sensor physically sits, only what it
    /// measures — and the gradient is not a cooling verdict.
    public static let footnote = """
    A schematic, not a photograph: Ice Cube knows what each sensor measures, \
    not where it sits. Whether cooling is getting worse is a question for \
    Cooling History, which has the watts and a baseline behind it.
    """
}
