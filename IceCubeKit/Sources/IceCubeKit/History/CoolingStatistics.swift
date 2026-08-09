// CoolingStatistics.swift — the small numerical pieces the cooling-history verdict is built from.

import Foundation

/// Median, nearest-rank percentiles and UTC day bucketing for cooling history.
///
/// **Median everywhere, never mean.** `R`'s error distribution has a long
/// *right* tail: every way the settle rule can be fooled — a window that just
/// barely settled during a slow ramp — produces an `R` that is too **high**
/// (docs/THERMAL.md records a real 1.89 °C/W transient beside the true 1.04).
/// A mean would be dragged upward by exactly the readings trusted least, in
/// exactly the direction of the claim this feature most fears getting wrong.
public enum CoolingStatistics {
    /// The median; an even count averages the two middle values.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Nearest-rank percentile, `p` in 0...100. No interpolation: with counts
    /// as low as three, interpolation implies precision that is not there.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[rank.clamped(to: 1 ... sorted.count) - 1]
    }

    /// UTC days since 1970 — the statistical unit the trend runs on.
    ///
    /// UTC and not the user's calendar, deliberately: this is a bucket, not a
    /// calendar entry anyone reads. A boundary that moved when the user flew
    /// to Tokyo could never be re-folded to the same answer, and DST does not
    /// exist at UTC — which is also what lets trend epochs be compared across
    /// a clock change without a bucket swallowing or losing an hour.
    public static func dayIndex(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }

    /// The UTC noon of a day index — for naming a day back to the user
    /// without the boundary ambiguity midnight would invite.
    public static func dayDate(_ day: Int) -> Date {
        Date(timeIntervalSince1970: Double(day) * 86400 + 43200)
    }
}
