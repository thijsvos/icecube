// PopoverFanCard.swift — the popover's fan card: one row per fan, with the live RPM readout.

import AppKit
import IceCubeKit
import SwiftUI

/// The fan readouts, grouped as a titled card.
///
/// Split out of `PopoverView` for size. It owns no state — `AppState` comes
/// in, everything else is derived — so extracting it changed no lifecycle:
/// the popover has no `@State` or `@AppStorage` to move.
struct PopoverFanCard: View {
    let state: AppState

    var body: some View {
        fanCard
    }

    /// The fan readouts, grouped as a titled card.
    private var fanCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
            Text("Fans").premiumSectionLabel()
            fanSection
        }
        .popoverCard()
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.fans) { fan in
                fanRow(fan)
            }
        }
    }

    private func fanRow(_ fan: Fan) -> some View {
        // Derived once so every part of the row answers from the same snapshot
        // rather than re-deriving from `fan` four times.
        let activity = FanActivity(fan)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fan.name)
                    .font(.callout.weight(.medium))
                // Beside the NAME, not the number. The number is right-aligned,
                // so anything reserved next to it pushes the number left even
                // when empty. Here the Spacer absorbs the hint appearing and
                // disappearing, so the reading never moves — which is the rule
                // this popover holds to: no reflow on data change.
                if let heading = activity.rampTargetRPM {
                    Text(verbatim: "→ \(RPM.text(heading))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity)
                }
                Spacer()
                rpmReadout(fan, activity: activity)
            }
            // Keyed on the hint's PRESENCE, not on `activity`: the value is
            // Equatable but carries `fillFraction`, so it differs on every 1 Hz
            // reading and would animate this row continuously.
            .animation(state.readingAnimation, value: activity.rampTargetRPM != nil)
            FanSpeedBar(
                fraction: activity.fillFraction,
                target: activity.rampTargetFraction,
                animated: state.chartSettings.smoothReadings
            )
        }
    }

    /// The current RPM, prominent, with a quiet unit label, plus where the fan
    /// is heading while it is still getting there.
    ///
    /// The destination slot is **permanently reserved** rather than inserted
    /// when needed. An earlier version appended "→ target" only while ramping,
    /// which toggled on and off every tick and shoved the number sideways; a
    /// fixed-width slot shows the same information without ever reflowing.
    ///
    /// Worth showing because the gap can be large and slow: switching from
    /// Automatic (where macOS may park the fans at 0) to a curve commands the
    /// new speed within a second, but the fan takes many seconds to physically
    /// wind up. Without this the popover reads "0 RPM" while everything is in
    /// fact working, which is indistinguishable from broken.
    private func rpmReadout(_ fan: Fan, activity: FanActivity) -> some View {
        HStack(spacing: 3) {
            if activity.readout == .starting {
                Text("starting…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(RPM.text(fan.actualRPM))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("RPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(state.readingAnimation, value: Int(fan.actualRPM))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(fan.name) fan: \(RPM.labeled(fan.actualRPM)), target \(RPM.labeled(fan.targetRPM))"
        )
    }
}
