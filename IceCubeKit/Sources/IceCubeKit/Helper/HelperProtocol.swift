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
    /// Older entries (v2–v15) are in [docs/PROTOCOL-HISTORY.md]. They are kept
    /// because each one records a real hardware finding, and moved because a
    /// changelog that grows without bound eventually buries the rule above it —
    /// which is the part that has to be read before a bump, not after.
    ///
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
    /// v19: log honesty on wake. The wake re-assert now runs behind the safety
    ///     verdict instead of in front of it — the app's heartbeat cannot tick
    ///     while the machine sleeps, so a non-persisting curve is always about
    ///     to be reverted on waking, and announcing "re-asserting curve
    ///     control" first described the opposite of what happened. Blind
    ///     temperature ticks are also reported once per spell rather than once
    ///     each: one wake produced six identical lines for a single reconnect.
    public static let protocolVersion = "19"
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

    /// Rebuilds a status from its JSON, as it arrives over XPC.
    ///
    /// - Throws: when the payload does not decode — which the app treats as a
    ///   dead connection rather than a fatal error, since the daemon on the
    ///   other end may be a different version.
    public static func decode(_ data: Data) throws -> HelperStatus {
        try JSONDecoder().decode(HelperStatus.self, from: data)
    }
}
