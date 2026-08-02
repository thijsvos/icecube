// DecisionTimelineView.swift — what the fan controller decided, in its own words, newest first.

import IceCubeKit
import SwiftUI

/// The daemon's decision log, rendered.
///
/// This is the answer to "why did my fans just do that", and until now it did
/// not exist anywhere a user could reach: the daemon wrote these sentences,
/// shipped them over XPC, and the app discarded them. The only way to read them
/// was `log show --predicate 'subsystem == "io.github.thijsvos.icecube"'`, which
/// is not a thing to ask of someone filing a bug.
///
/// It lives in the Sensors window beside **Export Diagnostics…** deliberately —
/// that is where a person who has come to report something already is, and the
/// same decisions are now in the exported JSON.
///
/// The text is the daemon's, verbatim. No re-wording, no summarising: those
/// sentences were written for exactly this moment.
struct DecisionTimelineView: View {
    let decisions: [DecisionEvent]

    private static let clock: Date.FormatStyle = .dateTime.hour().minute().second()

    var body: some View {
        // Fixed height with its own scroller. The Sensors window sizes itself
        // arithmetically from its content (`SensorsWindowMetrics`), and a
        // section that grows with uptime would make that sum unknowable — the
        // window would open short and macOS would persist the clipped frame.
        ScrollView {
            content
        }
        .frame(height: SensorsWindowMetrics.decisionSectionHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if decisions.isEmpty {
                // Not an error state: a daemon that has just started genuinely
                // has nothing to say yet, and saying so beats an empty box.
                Text("No decisions yet — the fan controller logs one whenever it takes, holds or hands back the fans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ForEach(decisions.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.date, format: Self.clock)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Circle()
                            .fill(Self.colour(for: event.kind))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(event.kind.rawValue)
                        Text(event.text)
                            .font(.caption)
                            .foregroundStyle(event.kind == .safety ? Theme.warning : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Orange is reserved, as everywhere else in this app, for "you are driving
    /// the fans by hand" and "this needs your attention" — so only a safety
    /// decision gets it. The rest use the brand accent or recede.
    static func colour(for kind: DecisionEvent.Kind) -> Color {
        switch kind {
        case .safety: Theme.warning
        case .guardian: Theme.accent
        case .engaged: Theme.accent
        case .wake: Theme.accent
        case .released, .asleep, .selfTest, .other: .secondary
        }
    }
}
