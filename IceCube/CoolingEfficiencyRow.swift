// CoolingEfficiencyRow.swift — the °C-per-watt readout, and the sentence that stops it being misread.

import IceCubeKit
import SwiftUI

/// How many degrees this Mac pays per watt, shown only when that number is real.
///
/// Lives in the Sensors window rather than the popover for two reasons. The
/// popover is deliberately dense and the owner's standing note is that it must
/// not become "too much info" — and more importantly, this number **cannot be
/// shown without its caveat**. `R` is measured against an internal airflow
/// sensor, not the room, so it compares this Mac to its own history and to
/// nothing else. A bare `0.51 °C/W` in a corner of the popover would invite
/// exactly the cross-machine comparison it cannot support.
///
/// `docs/THERMAL.md` carries the full reasoning.
struct CoolingEfficiencyRow: View {
    let watts: Double?
    let resistance: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Power draw")
                    .font(.callout)
                Spacer()
                Text(watts.map { "\(String(format: "%.1f", $0)) W" } ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(watts == nil ? .secondary : Theme.warning)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Cooling efficiency")
                    .font(.callout)
                Spacer()
                Text(resistance.map { "\(String(format: "%.2f", $0)) °C/W" } ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(resistance == nil ? .secondary : Theme.accent)
            }

            // One line always visible, the full explanation on hover.
            //
            // The caveat is not optional — a bare °C/W figure invites the
            // cross-machine comparison it cannot support — but this window is
            // already near its height ceiling on a sensor-rich Mac, and three
            // wrapped lines of permanent caption would squeeze the sensor list
            // the window exists for. So: the load-bearing sentence on screen,
            // the rest a hover away, and the whole derivation in docs/THERMAL.md.
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(explanation)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The one sentence that must never be missed. When there is no reading it
    /// says waiting is normal, so a dash cannot read as broken.
    private var headline: String {
        guard resistance != nil else {
            return watts == nil
                ? "This Mac reports no power figure."
                : "Measuring — needs \(Int(CoolingEfficiency.settleWindow))s of steady load."
        }
        return "Lower is better. Compare with your own past readings, not other Macs."
    }

    /// The full version, on hover. Also the text `docs/THERMAL.md` expands.
    private var explanation: String {
        guard resistance != nil else {
            if watts == nil {
                return "This Mac reports no power figure, so cooling efficiency cannot be measured."
            }
            return "Measuring — this needs the temperature and power to hold steady for "
                + "\(Int(CoolingEfficiency.settleWindow)) seconds. It settles when the machine does."
        }
        return "Degrees the chip runs above its own airflow, per watt it draws. Lower is better "
            + "cooling, and it falls as the fans speed up. Because the reference is a sensor inside "
            + "this Mac rather than the room, compare it to your own past readings — not to another "
            + "machine."
    }

    private var accessibilityText: String {
        guard let resistance else { return "Cooling efficiency: not measurable right now" }
        let power = watts.map { "\(String(format: "%.1f", $0)) watts" } ?? "unknown power"
        return "Cooling efficiency \(String(format: "%.2f", resistance)) degrees Celsius per watt, at \(power)"
    }
}
