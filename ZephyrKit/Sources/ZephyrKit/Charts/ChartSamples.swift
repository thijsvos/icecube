// ChartSamples.swift — chart sample/bucket types and the min-max downsampler that enforces the point budget.

import Foundation

/// One raw chart sample: a value at a moment.
public struct ChartSample: Sendable, Equatable {
    public let time: Date
    public let value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

/// One rendered chart point: a time bucket's min/max band and average line.
/// Min-max bucketing (rather than plain decimation) is deliberate: a one-tick
/// temperature spike must survive downsampling — dropping extremes would make
/// the chart lie about exactly the events a thermal monitor exists to show.
public struct ChartBucket: Sendable, Equatable {
    /// Bucket midpoint — where the point is drawn on the x axis.
    public let time: Date
    public let min: Double
    public let max: Double
    public let avg: Double

    public init(time: Date, min: Double, max: Double, avg: Double) {
        self.time = time
        self.min = min
        self.max = max
        self.avg = avg
    }
}

/// Summary numbers for a series over the visible window (the row header's
/// `min / avg / max` readout plus the live value).
public struct SeriesStats: Sendable, Equatable {
    public let min: Double
    public let max: Double
    public let avg: Double
    public let latest: Double

    public init(min: Double, max: Double, avg: Double, latest: Double) {
        self.min = min
        self.max = max
        self.avg = avg
        self.latest = latest
    }
}

public enum ChartDownsampler {
    /// Reduces `samples` within `[start, end]` to at most `budget` buckets.
    ///
    /// PLAN.md §1.2 makes ≤ ~600 visible points per series a **hard budget**:
    /// a raw 60-minute window (3600 points × several series) sits in Swift
    /// Charts' documented degradation zone. When the visible samples already
    /// fit the budget they pass through as one bucket each (min = max = avg);
    /// otherwise fixed-width buckets keep extremes and average.
    public static func downsample(
        _ samples: [ChartSample],
        from start: Date,
        to end: Date,
        budget: Int
    ) -> [ChartBucket] {
        precondition(budget > 0)
        let visible = samples.filter { $0.time >= start && $0.time <= end }
        guard !visible.isEmpty else { return [] }
        guard visible.count > budget else {
            return visible.map { ChartBucket(time: $0.time, min: $0.value, max: $0.value, avg: $0.value) }
        }

        let width = end.timeIntervalSince(start) / Double(budget)
        // Accumulate each sample into its bucket by index; a sample exactly at
        // `end` belongs to the last bucket.
        var accum = [(lo: Double, hi: Double, sum: Double, n: Int)](
            repeating: (.infinity, -.infinity, 0, 0), count: budget
        )
        for sample in visible {
            let b = Swift.min(Int(sample.time.timeIntervalSince(start) / width), budget - 1)
            accum[b].lo = Swift.min(accum[b].lo, sample.value)
            accum[b].hi = Swift.max(accum[b].hi, sample.value)
            accum[b].sum += sample.value
            accum[b].n += 1
        }
        // Empty buckets (no samples in that slice of time) are simply omitted.
        return accum.enumerated().compactMap { b, bucket in
            guard bucket.n > 0 else { return nil }
            return ChartBucket(
                time: start.addingTimeInterval((Double(b) + 0.5) * width),
                min: bucket.lo, max: bucket.hi, avg: bucket.sum / Double(bucket.n)
            )
        }
    }

    /// Stats over the visible window (nil when nothing is visible).
    public static func stats(_ samples: [ChartSample], from start: Date, to end: Date) -> SeriesStats? {
        let visible = samples.filter { $0.time >= start && $0.time <= end }
        guard let last = visible.last else { return nil }
        var lo = Double.infinity, hi = -Double.infinity, sum = 0.0
        for sample in visible {
            lo = Swift.min(lo, sample.value)
            hi = Swift.max(hi, sample.value)
            sum += sample.value
        }
        return SeriesStats(min: lo, max: hi, avg: sum / Double(visible.count), latest: last.value)
    }
}
