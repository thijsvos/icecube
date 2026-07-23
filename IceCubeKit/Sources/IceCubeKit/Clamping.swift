// Clamping.swift — a single `clamped(to:)` so the codebase stops hand-rolling min(max(...)).

import Foundation

public extension Comparable {
    /// This value confined to `range`. Replaces the repeated `min(max(...))`
    /// idiom (which also had to fight the `FanCurve.max` name inside the type).
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
