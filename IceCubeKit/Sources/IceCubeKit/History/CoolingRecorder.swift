// CoolingRecorder.swift — the gate between the live settle window and a record kept for a year.

import Foundation

/// Decides, once per tick, whether the current settled window has earned a
/// place in the history file — and names the reason whenever it has not.
///
/// The live readout and the file answer different questions. `isSettled` is
/// deliberately permissive — a false dash costs one second of `—` — but a
/// record is kept for a year and averaged into verdicts, so every gate here
/// is **stricter** than the live rule, and none of them touches it.
public struct CoolingRecorder: Sendable {
    // MARK: - Constants, and the measurements that set them

    /// At most one record per five minutes of wall clock, however long the
    /// machine stays settled and however often it re-settles.
    ///
    /// Two readings 20 s apart are one reading written twice; five minutes
    /// is long enough that the workload has plausibly moved, so each record
    /// carries new information. The throttle is **global**, not
    /// per-episode — a machine that settles and breaks every 25 s must not
    /// emit every 25 s — which makes "never more than 288 records a day" a
    /// provable property, and that property is the whole retention budget
    /// (`CoolingHistory.maximumRawRecords` = 7 × 288).
    public static let minimumSpacing: Duration = .seconds(300)

    /// Double the live 5 W floor, on purpose. THERMAL.md measured a 9 %
    /// spread between two readings at 8.6–9.0 W against 2 % at 21.5–24.0 W;
    /// a datum whose own noise is 9 % cannot support a 10 % claim, and
    /// recording it averages noise into the baseline. 10 W sits above the
    /// measured 7.9 W true idle, so an ordinarily busy machine still
    /// records. Honest gap: nothing has been measured between 9 W and 21 W —
    /// this is the smallest defensible step above the known-noisy point,
    /// and the constant to raise if a field reading finds 12 W still noisy.
    public static let minimumWatts: Double = 10

    /// The settled window must be *dense*, not merely long: at most this
    /// many seconds between consecutive samples, and at least
    /// ``minimumSamples`` of them.
    ///
    /// A bare count cannot be the gate — the poll interval is
    /// user-configurable (1, 2 or 5 s), so "10 samples" would refuse a
    /// clean 5 s cadence forever while admitting an App-Napped loop that
    /// surfaced ten times in a burst. Six seconds is one missed poll at the
    /// slowest cadence; a throttled loop's gaps are far wider.
    public static let maximumSampleGap: TimeInterval = 6
    /// A full 20 s window at the slowest (5 s) cadence, with margin for one
    /// dropped poll. `isSettled` accepts two samples; two is a line through
    /// two points, not evidence.
    public static let minimumSamples = 4

    /// How much the fan fraction may move across the recorder's own window
    /// and still count as "one fan speed". The settle rule bounds power and
    /// die and never looks at the fans — the exact axis records are banded
    /// on. 0.05 of maximum is the figure `ControlAlertRules.pinnedFraction`
    /// already justifies: wider than tachometer wobble at speed, far
    /// narrower than any curve step. At the measured sensitivity it admits
    /// ~2.3 % of `R`, comparable to the 2 % repeatability.
    public static let fanSettleTolerance = 0.05

    /// Two fans at 0.9 and 0.0 of maximum are not "0.45 of maximum" — they
    /// are an incident, and `ThermalDiagnosis.Cooling.stalled` already
    /// names it in seconds. A machine whose fans honestly run this far
    /// apart records nothing and is told so via ``lastRefusal``. Set from
    /// one 2-fan machine whose fans run one curve output; the constant most
    /// likely to need widening from field reports.
    public static let maximumFanDisagreement = 0.10

    // MARK: - State

    /// Why the last tick produced nothing — the app refuses out loud.
    public private(set) var lastRefusal: Refusal?

    /// Why the last tick produced no record — one case per gate above, each
    /// carrying the measurement that failed it.
    ///
    /// Named rather than collapsed to `nil` for the same reason
    /// ``ThermalTimeConstant/Refusal`` is: a window that says "no reading" is far
    /// less useful than one that says which of seven conditions the machine has
    /// not met. Every gate here is deliberately stricter than the live
    /// ``CoolingEfficiency/isSettled(_:)`` rule, so a user watching a settled
    /// readout **will** see records refused and is owed the reason.
    ///
    /// Each associated value is the measured quantity that failed its own gate, in
    /// that gate's units, so the app can say "fans 0.14 apart, tolerance 0.10"
    /// rather than printing a bare label.
    public enum Refusal: Sendable, Equatable {
        /// The live tracker has no settled window at all.
        case unsettled
        /// Fans present but none readable — not the same as fanless.
        case fansUnreadable
        /// Per-fan fractions spread wider than ``maximumFanDisagreement``; carries
        /// the spread. Two fans at 0.9 and 0.0 are an incident, not "0.45 of
        /// maximum".
        case fansDisagree(Double)
        /// The fan fraction swung more than ``fanSettleTolerance`` across the
        /// window; carries the swing. The settle rule bounds power and die and
        /// never looks at the fans — the exact axis records are banded on.
        case fansMoving(Double)
        /// Mean draw below ``minimumWatts``; carries the wattage. A datum whose own
        /// noise is 9 % cannot support a 10 % claim.
        case lowPower(Double)
        /// The window was too sparse to trust (throttled poll loop).
        case sparseWindow(samples: Int, widestGap: TimeInterval)
        /// Inside ``minimumSpacing`` of the last emitted record. Global, not
        /// per-episode: "never more than 288 records a day" is the whole retention
        /// budget.
        case tooSoon
    }

    /// Monotonic instant of the last emitted record. Spacing runs on the
    /// monotonic clock and stamps run on the wall clock — the
    /// `SafetyMonitor.heartbeatAge` precedent — so an NTP step can move a
    /// record's *date* but can never make the recorder burst or stall.
    private var lastEmitted: ContinuousClock.Instant?
    /// The trailing window of fan fractions, for the fan-stability gate.
    private var fanFractions: [(date: Date, fraction: Double)] = []

    public init() {}

    // MARK: - The gate

    /// Feeds one tick; returns a record when one is earned.
    ///
    /// - Parameters:
    ///   - snapshot: this tick's poll result (fans and wall-clock date).
    ///   - settled: the live tracker's settled window, or nil.
    ///   - elapsed: the monotonic now, for spacing.
    public mutating func ingest(
        _ snapshot: SMCSnapshot,
        settled: CoolingEfficiency.SettledWindow?,
        elapsed: ContinuousClock.Instant
    ) -> CoolingRecord? {
        // Fan context first: it also maintains the fan-stability window,
        // which must advance every tick, settled or not.
        guard let context = FanContext.measure(snapshot.fans) else {
            fanFractions.removeAll()
            lastRefusal = .fansUnreadable
            return nil
        }
        if context.band != .fanless {
            fanFractions.append((snapshot.date, context.meanFraction))
            let cutoff = snapshot.date.addingTimeInterval(-CoolingEfficiency.settleWindow)
            fanFractions.removeAll { $0.date < cutoff || $0.date > snapshot.date }
        }

        guard let settled else {
            lastRefusal = .unsettled
            return nil
        }
        if context.band != .fanless {
            if context.disagreement > Self.maximumFanDisagreement {
                lastRefusal = .fansDisagree(context.disagreement)
                return nil
            }
            let fractions = fanFractions.map(\.fraction)
            let swing = (fractions.max() ?? 0) - (fractions.min() ?? 0)
            if swing > Self.fanSettleTolerance {
                lastRefusal = .fansMoving(swing)
                return nil
            }
        }
        guard settled.watts >= Self.minimumWatts else {
            lastRefusal = .lowPower(settled.watts)
            return nil
        }
        guard settled.sampleCount >= Self.minimumSamples,
              settled.maxGapSeconds <= Self.maximumSampleGap
        else {
            lastRefusal = .sparseWindow(
                samples: settled.sampleCount, widestGap: settled.maxGapSeconds
            )
            return nil
        }
        if let lastEmitted, elapsed - lastEmitted < Self.minimumSpacing {
            lastRefusal = .tooSoon
            return nil
        }

        lastEmitted = elapsed
        lastRefusal = nil
        return CoolingRecord(
            date: snapshot.date,
            resistance: settled.resistance,
            dieCelsius: settled.dieCelsius,
            ambientCelsius: settled.ambientCelsius,
            watts: settled.watts,
            band: context.band,
            fanFraction: context.meanFraction,
            fanRPM: context.meanRPM,
            sampleCount: settled.sampleCount,
            durationSeconds: settled.duration
        )
    }
}
