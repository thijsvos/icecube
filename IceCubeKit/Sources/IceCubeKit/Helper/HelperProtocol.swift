// HelperProtocol.swift — the XPC contract between the app and the root helper daemon.

import Foundation

/// Shared identifiers and timing constants for the app↔helper channel.
public enum HelperConstants {
    /// The launchd mach service (must match the LaunchDaemons plist).
    public static let machServiceName = "io.github.thijsvos.icecube.helper.xpc"
    /// The helper's bundle identifier (its code-signing identifier).
    public static let helperBundleID = "io.github.thijsvos.icecube.helper"
    /// The app's bundle identifier (what the helper pins incoming callers to).
    public static let appBundleID = "io.github.thijsvos.icecube"
    /// Protocol version; both sides must agree.
    ///
    /// Bump on any change to what the daemon DOES, not merely to the shape of
    /// this interface. Replacing the app does not restart the running daemon —
    /// launchd keeps the old one — and if the version still matches, the app
    /// connects happily to stale code. That cost three manual re-registrations
    /// while verifying the safety fixes below, each time silently testing the
    /// previous build. A mismatch is cheap: the setup flow offers one button.
    ///
    /// v2: FanConfig gained curve fields (Phase 4).
    /// v3: HelperStatus gained `guardianActive`.
    /// v4: daemon safety behaviour changed (revert/engage race guards, sensor
    ///     discovery, boot-promise handling) with no interface change.
    /// v5: HelperStatus reports `activeCurve`. Additive and optional, so an old
    ///     daemon does not *break* a new app — but without the bump the app
    ///     silently keeps talking to a daemon that never sends it, and the
    ///     preset highlight it fixes stays broken for everyone who upgrades.
    ///     "It still decodes" is not the bar; "the user gets the fix" is.
    /// v6: the daemon keeps its sensor-key cache across a hand-back to macOS,
    ///     and retries a failed temperature read in place instead of skipping
    ///     a tick. Behaviour only — but it is the difference between taking
    ///     control instantly and taking up to 6 s, so users need the new one.
    /// v7: tried a full-drive "breakaway" push for stopped fans, then reverted
    ///     it in v8 — measured on hardware, it changed nothing (see v8).
    /// v8: breakaway removed. Fan spin-up from rest is firmware-paced: driving
    ///     a stopped fan at 6800 instead of 4250 produced an identical ramp
    ///     (295/573/839/1731… either way) and an identical 1.5 s dead time, so
    ///     the push was cost without benefit.
    /// v9: since the ramp cannot be made faster (v8), the daemon stops starting
    ///     from rest. On a warm machine (>= 55 °C die) it catches a fan that is
    ///     coasting below its own `Mn` with nobody forcing it, and holds it at
    ///     the floor instead of letting it stop — so switching away from macOS
    ///     mode is a ~1 s adjustment rather than a 4.4 s standing start. Three
    ///     details are load-bearing, all measured on Mac14,9:
    ///     - the catch is on the way DOWN (below `Mn`, no debounce, and
    ///       evaluated the instant the app asks for auto). Handed back from
    ///       4400 RPM the fans read zero four seconds later, so waiting for a
    ///       stop, or for a two-tick debounce, arrives after the event.
    ///     - a fan far below `Mn` gets ~50 % drive until it is most of the way
    ///       back, then settles onto the floor. Unlike the v7 breakaway (6800
    ///       vs 4250, no difference), this end of the scale matters: commanded
    ///       2317 from rest the fan sat still 6.5 s; commanded ~4550 it moved
    ///       in 1.5 s.
    ///     - it matches any non-forced mode, not just SMC mode 0. Our own
    ///       hand-back writes mode 3, so the old orphan ladder never saw the
    ///       fans macOS declined to reclaim, and they sat dead indefinitely.
    /// v10: the breakaway triggers below 75 % of `Mn`, not merely at a
    ///     standstill. v9 caught a fan mid-coast at 293 RPM, commanded it its
    ///     own 2317 minimum, and watched it decay to a stop anyway and sit
    ///     there 9.4 s — a fan far below its minimum needs more than its
    ///     minimum whether or not it has technically stopped yet.
    /// v11: the keep-spinning decision moved to the *moment* of the hand-back
    ///     (`FanGuardian.handBack`), because the tick cannot make it in time.
    ///     Traced twice on hardware: the fans coast to a standstill in ~2.5 s,
    ///     the next tick landed 1.7 s and 3.0 s later, and neither catch helped
    ///     — a fan at 293 RPM commanded its 2317 minimum decayed to a stop
    ///     anyway, and once stopped both runs took the same 9.4 s to move
    ///     again, one commanded 2317 and the other 4600. Drive buys nothing
    ///     (v8's finding, at the other end of the range), and restart latency
    ///     is not even consistent: an engage from a settled stop took 1.1 s.
    ///     Nothing here is controllable, so the fans must simply never stop. On
    ///     a warm machine they now ramp DOWN to their floor with no gap.
    /// v12: the hand-back holds at 45 °C, not 55, and logs its decision either
    ///     way. v11 never fired once on hardware: leaving a working Balanced
    ///     curve the die read 52.9 °C with the fans at 3226 RPM holding it
    ///     there, so it gated on the very temperature it was about to destroy.
    ///     The tick keeps the 55 °C bar — it restarts stopped fans, which is
    ///     expensive; this path keeps turning fans turning, which is free.
    /// v13: a failed fan read is no longer fabricated into a value. `readFans`
    ///     swallowed every failure with `(try? …) ?? 0`, so a fan whose mode
    ///     read missed came back as `.system` with target 0 — bit-for-bit what
    ///     "macOS took the fans off us" looks like. One of those logged a
    ///     read-back mismatch on ordinary app restarts (`resetPort()` closes
    ///     the connection and the next read is the one most likely to miss);
    ///     two in a row reverted a healthy curve to auto, verified by mutation
    ///     test. Absent keys are still tolerated — only transport failures
    ///     retry and then throw, so the tick is skipped rather than acted on.
    /// v14: write sequences are serialized, and a stale one stands down.
    ///     `DaemonCore` is an actor, but `engageManual` writes a mode and a
    ///     target per fan and suspends on every one, so two engages interleaved
    ///     and the fans ended up wherever the last WRITE landed rather than
    ///     wherever the newest INTENT said. Caught on an app restart: quitting
    ///     starts the guardian writing the fan floor, the relaunch applies a
    ///     curve 250 ms later, and read-back found `target 2317 != 3400`.
    ///     `applyGeneration` covered apply-vs-apply and `revertGeneration`
    ///     covered revert-vs-engage; the guardian's own engage sat outside both.
    /// v15: `setAllAuto` (the "Turn Off Fan Control" path) is pinned by test as
    ///     the one hand-back that does NOT keep the fans — with the macOS
    ///     preset gone it is a user's only way to release them, so the warm-
    ///     machine floor hold must not fire there. No behaviour change; the
    ///     bump is so a daemon predating the guarantee cannot be talked to.
    /// v16: the daemon's unified-log subsystem is redirected under test, so
    ///     scripted 110 °C and firmware-rejection scenarios stop appearing in
    ///     `log show` as things that happened to this Mac. No runtime change —
    ///     bumped only so the installed daemon matches source, which is the
    ///     mistake this whole list exists to prevent.
    /// v17: adds `selfTestWritePath` — the write-path self-test PLAN.md §4.3.6
    ///     called for and §7 lists as the mitigation for "Apple changes SMC
    ///     behaviour in a point update". Until now nothing could tell "fan
    ///     control works on your Mac" from "fan control silently does nothing",
    ///     and the diagnostics a new-model report asks for described only reads.
    /// v18: the self-test restores the config it interrupted. v17 ended in
    ///     `.auto` on the assumption the app would re-apply — it does not
    ///     (`autoResumeIfNeeded` latches once per session), so on hardware the
    ///     very first run swapped a live Balanced curve for the guardian's
    ///     floor hold and left it there. A diagnostic must not change settings.
    public static let protocolVersion = "18"
    /// How often the app sends a heartbeat while connected.
    public static let heartbeatInterval: TimeInterval = 5
    /// SAFETY: no heartbeat for this long → the daemon's watchdog reverts to
    /// auto (always in manual mode; in curve mode unless persistence is on).
    public static let watchdogTimeout: TimeInterval = 15
    /// The daemon's control/safety tick.
    public static let tickInterval: TimeInterval = 2

    /// The unified-log subsystem — redirected under test.
    ///
    /// `DaemonCoreTests` drives the real actor against a scripted fake
    /// firmware, deliberately including a 110 °C sensor, a firmware rejection
    /// and an unwritable mode key. Those landed in the SAME subsystem as the
    /// shipping daemon, so `log show` during a real investigation came back
    /// salted with `SAFETY: forcing maximum cooling — Tp01 at 110 °C` for a
    /// Mac that had done nothing of the kind. It derailed two diagnoses in one
    /// session before the process column gave it away.
    ///
    /// Only the daemon's own logging routes through this: the app's loggers
    /// name the subsystem directly, and the app is never the one under test.
    public static let logSubsystem: String = {
        let environment = ProcessInfo.processInfo.environment
        let underTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
            || ProcessInfo.processInfo.processName.contains("testing-helper")
            || ProcessInfo.processInfo.processName.hasSuffix("PackageTests")
        return underTest ? "io.github.thijsvos.icecube.tests" : "io.github.thijsvos.icecube"
    }()
}

/// The XPC interface the helper daemon exposes.
///
/// Deliberately tiny (PLAN.md §4.2): configuration is one Codable blob, and
/// there is no method that can weaken the daemon-side safety enforcement —
/// "cannot be disabled by the app" is enforced by this API's shape.
@objc public protocol HelperProtocol {
    /// Protocol-version handshake; mismatch → the app asks to re-register.
    func getVersion(reply: @escaping @Sendable (String) -> Void)
    /// Applies a JSON-encoded ``FanConfig``. The daemon clamps, sequences,
    /// verifies by read-back, and may refuse (returned error).
    func apply(configData: Data, reply: @escaping @Sendable (NSError?) -> Void)
    /// Reverts every fan to automatic control immediately.
    func setAllAuto(reply: @escaping @Sendable (NSError?) -> Void)
    /// Feeds the watchdog. Sent every ``HelperConstants/heartbeatInterval``.
    func heartbeat()
    /// A JSON-encoded ``HelperStatus`` snapshot for the UI and diagnostics.
    func getStatus(reply: @escaping @Sendable (Data) -> Void)
    /// Checks whether this Mac's fans can actually be driven, and returns a
    /// JSON-encoded ``WritePathReport``. Writes each fan's current target back
    /// to itself and reverts, so it commands no change (PLAN.md §4.3.6).
    func selfTestWritePath(reply: @escaping @Sendable (Data) -> Void)
}

/// What the daemon reports about itself (JSON over XPC).
public struct HelperStatus: Codable, Sendable, Equatable {
    public var protocolVersion: String
    /// The mode currently enforced by the daemon (not merely requested).
    public var mode: FanConfig.Mode
    /// Clamped per-fan targets in force when `mode == .manual`.
    public var appliedTargets: [Int: Double]
    /// Which write branch this machine needed: `"direct"` (M1/M2-style) or
    /// `"ftst"` (M3/M4-style unlock). `nil` until the first manual engage.
    public var unlockBranch: String?
    /// Whether the last write sequence passed read-back verification.
    public var lastWriteVerified: Bool
    /// True while the daemon's guardian is driving the fans itself in `.auto`
    /// mode — i.e. the Mac is hot and macOS isn't cooling it. Lets the UI
    /// explain "Automatic, but Ice Cube is actively cooling."
    public var guardianActive: Bool
    /// Recent safety decisions, newest last (bounded), for UI + bug reports.
    public var recentEvents: [String]
    /// The curve the daemon is enforcing right now, when `mode == .curve`.
    ///
    /// Reported so the app can show which preset is active even when it did not
    /// send it — after a reboot the daemon resumes a persisted curve before the
    /// app exists, and an app with no memory of it used to leave every preset
    /// button unlit while the fans audibly ran. **Optional on purpose**: a
    /// missing key decodes to nil, so adding it cannot break a peer that
    /// predates it.
    public var activeCurve: FanCurve?

    public init(
        protocolVersion: String = HelperConstants.protocolVersion,
        mode: FanConfig.Mode = .auto,
        appliedTargets: [Int: Double] = [:],
        unlockBranch: String? = nil,
        lastWriteVerified: Bool = false,
        guardianActive: Bool = false,
        recentEvents: [String] = [],
        activeCurve: FanCurve? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.mode = mode
        self.appliedTargets = appliedTargets
        self.unlockBranch = unlockBranch
        self.lastWriteVerified = lastWriteVerified
        self.guardianActive = guardianActive
        self.recentEvents = recentEvents
        self.activeCurve = activeCurve
    }

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> HelperStatus {
        try JSONDecoder().decode(HelperStatus.self, from: data)
    }
}
