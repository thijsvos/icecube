// DecisionMarkers.swift — which decisions earn a line on the chart, and what colour it is.

import IceCubeKit
import SwiftUI

/// Chooses the decisions worth drawing over a chart's visible time window.
///
/// Its own pure type, not a filter inlined in `ChartRowView`, for two reasons.
/// It is drawn once per row per tick, and it is the only piece of this feature
/// that can make the charts *wrong* rather than merely ugly — so it gets tests
/// instead of trust.
enum DecisionMarkers {
    /// The kinds that get a line.
    ///
    /// Not every decision is a chart event. `.selfTest` and `.other` are the
    /// daemon talking to its log — real information, but they explain nothing
    /// about a moving fan line, and a marker per tick would turn a 5-minute
    /// window into a picket fence and bury the ceiling trip that actually
    /// matters. The six kept here are exactly the ones that change who is
    /// driving the fans.
    static let notable: Set<DecisionEvent.Kind> = [
        .safety, .guardian, .engaged, .released, .wake, .asleep,
    ]

    /// The decisions to draw for a chart showing `window`.
    ///
    /// Events outside the window are dropped rather than clamped to its edge:
    /// a marker pinned at t=0 would claim the daemon did something at the
    /// left edge of the chart when it happened an hour earlier.
    ///
    /// The result keeps `decisions` order (the daemon appends chronologically),
    /// so a redraw cannot reshuffle the markers under the pointer.
    static func visible(
        _ decisions: [DecisionEvent],
        in window: ClosedRange<Date>
    ) -> [DecisionEvent] {
        decisions.filter { notable.contains($0.kind) && window.contains($0.date) }
    }
}
