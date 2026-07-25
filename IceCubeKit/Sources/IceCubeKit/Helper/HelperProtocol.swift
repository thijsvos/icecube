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
    public static let protocolVersion = "6"
    /// How often the app sends a heartbeat while connected.
    public static let heartbeatInterval: TimeInterval = 5
    /// SAFETY: no heartbeat for this long → the daemon's watchdog reverts to
    /// auto (always in manual mode; in curve mode unless persistence is on).
    public static let watchdogTimeout: TimeInterval = 15
    /// The daemon's control/safety tick.
    public static let tickInterval: TimeInterval = 2
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
