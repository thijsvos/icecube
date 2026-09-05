// CurveFitRow.swift — the curve editor's "fit this Mac" control: a target, a button, and the honest answer.

import IceCubeKit
import SwiftUI

/// Asks the machine for a curve, and shows what it said.
///
/// One row rather than a panel because the curve editor's window is already
/// dense — `PLAN.md` records what happened the last time a surface here grew a
/// fifth control — and because the *output* of this row is the plot above it,
/// not the row itself. The user drags a temperature, presses the button, and
/// the curve lands in the editor as ordinary draggable points they can then
/// argue with.
///
/// That "argue with" is the design. `docs/THERMAL.md` parks a model that
/// commands the fans on the grounds that one which has never run on hardware
/// does not get a vote. This does not give it a vote: it gives it a proposal,
/// and Apply is still the person's click.
struct CurveFitRow: View {
    @Bindable var state: AppState
    let model: CurveEditorModel

    /// What to hold under sustained load. Window-local: it is a question being
    /// asked, not a setting, and the answer arrives before the window closes.
    @State private var holdCelsius: Double = 85

    private var verdict: CurveDerivation.Verdict {
        state.deriveCurve(holdingAt: holdCelsius)
    }

    private var derivedCurve: FanCurve? {
        if case let .derived(derivation) = verdict {
            derivation.curve
        } else {
            nil
        }
    }

    var body: some View {
        let summary = CurveDerivationCopy.summary(verdict, style: state.temperatureUnit.style)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                // Fixed width and monospaced digits for the same reason the
                // hysteresis and ramp labels below carry them: nothing may move
                // while a slider is under the pointer.
                Text("Hold \(state.temperatureUnit.style.reading(holdCelsius))")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .leading)
                Slider(value: $holdCelsius, in: CurveDerivation.targetRange, step: 1)
                    .frame(width: 110)
                    .controlSize(.mini)
                Button("Fit to This Mac") {
                    if let curve = derivedCurve {
                        model.load(curve)
                    }
                }
                .disabled(derivedCurve == nil)
                Text(summary.headline)
                    .font(.caption)
                    .foregroundStyle(summary.isCaution ? Theme.warning : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            // Always shown, never a tooltip. The sentence says how many
            // readings the curve rests on, and a curve whose evidence is
            // hidden behind a hover is a curve people will apply without
            // reading what it is made of.
            Text(summary.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
