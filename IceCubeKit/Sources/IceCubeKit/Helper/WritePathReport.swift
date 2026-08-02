// WritePathReport.swift — what the daemon learned when it checked whether this Mac's fans can actually be driven.

import Foundation

/// The result of a write-path self-test (PLAN.md §4.3.6).
///
/// Ice Cube's fan-control write sequence is verified on exactly one machine —
/// the author's Mac14,9. The M3/M4 `Ftst` unlock and the M5 key rename are
/// implemented from community research and have never run on the hardware they
/// describe. Until now nothing could tell the difference between "fan control
/// works on your Mac" and "fan control silently does nothing on your Mac", and
/// the diagnostics report a new-model bug asks for described only *reads*: the
/// SMC key dump, the sensors, the fan ranges. Nothing about whether a write is
/// accepted, which unlock path this firmware needs, or whether a value that was
/// accepted was also honoured.
///
/// This is that missing half. It is deliberately a **value type in IceCubeKit**
/// rather than a log line, so it can be attached to a GitHub issue, embedded in
/// ``DiagnosticsReport``, and unit-tested.
public struct WritePathReport: Sendable, Codable, Equatable {
    /// What the firmware did with our writes.
    ///
    /// Five cases rather than a Bool because the failures are not
    /// interchangeable: a firmware that **refuses** the mode write needs a new
    /// unlock path, while a firmware that **accepts and then ignores** it needs
    /// a different write sequence entirely. Ice Cube has already hit the second
    /// kind — the revert that "succeeded" while leaving the fans stopped at
    /// 0 RPM (see `FanWriteSequencer.revertAllAuto`'s field correction) — and
    /// collapsing them into "failed" would have hidden it.
    /// `CaseIterable` so a test can assert every verdict produces a sentence —
    /// the guard that stops a future case shipping with a blank `summary`.
    public enum Verdict: String, Sendable, Codable, CaseIterable {
        /// Mode stuck at forced and the target read back as written. Fan
        /// control works on this machine.
        case verified
        /// The firmware refused the mode write, even after the `Ftst` unlock
        /// was tried. `detail` carries what it actually said.
        case rejected
        /// The writes were accepted and then not honoured — read-back
        /// disagreed. The nastiest failure, because everything *looks* fine.
        case notVerified
        /// No fan reported a usable `[Mn, Mx]` range, so there was nothing that
        /// could be driven safely. Normal on a fanless Mac (the M2 Air).
        case noUsableFans
        /// The test could not run: the SMC was unreadable, or it was asked for
        /// while something else already held the fans.
        case unavailable
    }

    public let verdict: Verdict
    /// `"Md"` or `"md"` — M5 renamed the fan-mode key, and knowing which one a
    /// generation uses is half of supporting it.
    public let modeKeySuffix: String?
    /// `"direct"` or `"ftst"` — which unlock this firmware needed. The single
    /// most valuable field for adding a new SoC generation.
    public let unlockBranch: String?
    public let fanCount: Int
    /// Per fan: the `[Mn, Mx]` the firmware reports. Advisory in firmware, but
    /// it is what every clamp in the daemon is built on, so a wrong one here
    /// explains a whole class of report.
    public let fanRanges: [Int: [Double]]
    /// Whether `Ftst` exists at all on this machine.
    public let hasFtstKey: Bool
    public let modelIdentifier: String
    public let osVersion: String
    public let testedAt: Date
    /// The firmware's own words on a failure, or a note on why it was skipped.
    /// Never a fabricated explanation — if there is nothing to say, this is nil.
    public let detail: String?

    public init(
        verdict: Verdict,
        modeKeySuffix: String? = nil,
        unlockBranch: String? = nil,
        fanCount: Int = 0,
        fanRanges: [Int: [Double]] = [:],
        hasFtstKey: Bool = false,
        modelIdentifier: String = HostInfo.modelIdentifier(),
        osVersion: String = HostInfo.osVersion(),
        testedAt: Date = Date(),
        detail: String? = nil
    ) {
        self.verdict = verdict
        self.modeKeySuffix = modeKeySuffix
        self.unlockBranch = unlockBranch
        self.fanCount = fanCount
        self.fanRanges = fanRanges
        self.hasFtstKey = hasFtstKey
        self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion
        self.testedAt = testedAt
        self.detail = detail
    }

    /// One sentence, written for the person who pressed the button rather than
    /// for the person who will read the JSON.
    public var summary: String {
        switch verdict {
        case .verified:
            let path = unlockBranch == "ftst"
                ? " Your firmware needed the Ftst unlock."
                : ""
            return "Fan control works on this Mac.\(path)"
        case .rejected:
            return "This Mac's firmware refused to hand over the fans. "
                + "Fan control will not work; monitoring is unaffected."
        case .notVerified:
            return "This Mac accepted the fan commands but did not act on them. "
                + "Please report this — it is the case Ice Cube most needs to hear about."
        case .noUsableFans:
            return "This Mac has no controllable fans. Monitoring works normally."
        case .unavailable:
            return detail ?? "The check could not run just now. Try again in a moment."
        }
    }

    /// True when the result is worth sending to the project. A clean `verified`
    /// on an already-supported machine tells nobody anything new; every other
    /// outcome does.
    public var isWorthReporting: Bool {
        switch verdict {
        case .rejected, .notVerified: true
        case .verified, .noUsableFans, .unavailable: false
        }
    }
}
