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
    /// Older entries (v2–v19) are in [docs/PROTOCOL-HISTORY.md]. They are kept
    /// because each one records a real hardware finding, and moved because a
    /// changelog that grows without bound eventually buries the rule above it —
    /// which is the part that has to be read before a bump, not after.
    ///
    /// v20: the sleep half of the sleep/wake contract. The daemon now registers
    ///     for IOKit power notifications and hands every fan back to the
    ///     firmware on `kIOMessageSystemWillSleep`, then writes no fan at all
    ///     until it wakes — except the temperature ceiling, which stays armed
    ///     because the ticks that run while parked are dark wakes. `F{i}Md = 1`
    ///     survives sleep on Apple Silicon (§3.4 assumed the firmware would drop
    ///     control for us by resetting `Ftst`; `Ftst` does not even exist on
    ///     Mac14,9), so before this the fans ran forced for the whole closed-lid
    ///     window — 16 min 34 s in the owner's own log — until an unrelated
    ///     Power Nap dark wake happened to run a tick and the watchdog fired.
    ///     A park is deliberately NOT a revert: `config`, the persisted curve
    ///     and the ceiling hysteresis all survive it, so wake resumes the user's
    ///     curve instead of silently landing in auto.
    /// v21: the dark-wake gate. The sleep latch may now drop only when a
    ///     `PowerCapabilities` read proves a display is powered. Before this,
    ///     the heartbeat-after-a-nap rule read a maintenance dark wake as a real
    ///     wake and drove both fans to 6800 RPM for 69 s inside a closed laptop
    ///     (owner's log, 2026-07-31, `[CDNPB]` rtc/Maintenance).
    ///
    ///     **The XPC surface is byte-identical — this bump exists purely to
    ///     ship the daemon.** Nothing else replaces a running helper: the app
    ///     compares this string and offers the update, so a daemon-only fix
    ///     with an unchanged protocol installs a new app beside the old,
    ///     buggy daemon and nothing ever says so. That is exactly what happened
    ///     on the first attempt to deploy this fix — the app logged
    ///     "setup: not shown", because from its point of view v20 was talking
    ///     to v20 and all was well. Any future daemon-only safety fix must bump
    ///     this for the same reason, protocol change or not.
    /// v22: errors the daemon replies with now carry their own message. Every
    ///     `IceCubeError` crossed XPC stripped of `errorDescription` — Swift
    ///     installs that through a lazy userInfo value provider, which is not
    ///     part of the encoded dictionary — so the app rendered "The operation
    ///     couldn't be completed. (IceCubeKit.IceCubeError error 7.)" for all
    ///     eight cases. `HelperService` now wires them through `WireError`,
    ///     which also carries a stable case name so the app can tell the
    ///     parked-for-sleep refusal from a real failure and hold the config
    ///     until the Mac wakes instead of showing a scare. **The XPC surface is
    ///     byte-identical**; the bump is here because the app's new
    ///     classification only works against a daemon that sends the name, and
    ///     a new app beside a v21 daemon would silently be the old bug — the
    ///     rule v21 above sets out.
    /// v23: the daemon's decision log reaches the app. Every meaningful choice
    ///     already went through `DaemonCore.record()` in plain prose and rode
    ///     over in `HelperStatus.recentEvents` — and the app dropped it: a grep
    ///     for `recentEvents` in the app target returned nothing. The strings
    ///     were computed, tested in ~34 places, transported, and shown to
    ///     nobody. `recentDecisions` adds the two things a bare string cannot
    ///     carry — a timestamp, so a decision can be drawn on the same axis as
    ///     the charts, and a `DecisionEvent.Kind`, so a ceiling trip is not
    ///     coloured like a routine engage.
    ///
    ///     The XPC surface gains one optional field and nothing else; the bump
    ///     is here because the daemon's behaviour changed (it now timestamps
    ///     and classifies), and because an app expecting decisions from a v22
    ///     helper would show an empty timeline with no explanation. Same rule
    ///     as v21 and v22.
    /// v24: the curve deadband is bounded at both ends. `CurveFollower` clamped
    ///     `hysteresisCelsius` with `max(0, …)` — a lower bound only — so a
    ///     deadband wider than the range a die actually moves through left the
    ///     follower **inert**: `effectiveTemp` never updated and the output
    ///     stayed wherever the first tick put it while the die climbed. It is
    ///     the one tuning value that can silently disable a curve, and not
    ///     every value reaching it comes from the editor's 0…8 slider — a
    ///     hand-edited config or a `FanConfig` off the wire decodes through
    ///     `decodeIfPresent ?? 4`, which applies no bound at all.
    ///
    ///     **The XPC surface is byte-identical.** The bump is here because
    ///     `CurveFollower` runs *inside the daemon*, so a new app beside a v23
    ///     helper is still the unfixed follower driving the fans — precisely
    ///     the failure the rule above was written after. Nothing in the app
    ///     could report it either, because from the app's side the curve was
    ///     accepted.
    /// v25: the revert-on-invalidation rule counts connections. The daemon
    ///     reverted on **any** dropped connection, having no idea whether
    ///     another app was still attached — so two instances (a dev build
    ///     beside the installed one, or a double launch) meant quitting either
    ///     one dropped fan control for both. It now reverts when the last
    ///     connection goes, which is what "nobody is supervising the fans any
    ///     more" actually means.
    ///
    ///     **The XPC surface is byte-identical.** The bump is here because a
    ///     v24 daemon behind a v25 app still drops the fans on the first
    ///     disconnect, and nothing on the app side can see that it did.
    /// v26: the daemon can finally see an M3's die sensors. Its candidate probe
    ///     list held 28 `Tp*` and 8 `Tg*` keys and **no `Te`, `Tf` or `Tc` key
    ///     at all**, while `docs/SMC-KEYS.md` had recorded since 2026-07-28 that
    ///     M3's die sensors are `Te0*`/`Tf*`. On that hardware `SensorReader`'s
    ///     `hasDie` guard could never pass: the daemon read as blind every tick,
    ///     `SafetyMonitor` reverted after three of them, and every curve came
    ///     undone about six seconds after the user applied it — while the app
    ///     showed correct temperatures the whole time, because the app
    ///     enumerates keys and the daemon deliberately cannot.
    ///
    ///     **The XPC surface is byte-identical.** The bump is here because the
    ///     daemon now admits sensors it previously could not, which is a
    ///     behaviour change on every unmapped Mac — and a v25 daemon behind a
    ///     v26 app is still the blind one. Nothing changes on M2, which uses the
    ///     curated map and never reaches this list.
    /// v27: a hand-back that did not reach the firmware is no longer recorded as
    ///     one. Four paths used to discard the write outcome and narrate success:
    ///     `revertAllAuto` returned silently when the mode key would not resolve;
    ///     the guardian's `.release` and `.reparkOrphans` branches recorded their
    ///     sentence *before* writing and then swallowed the result in `try?`; and
    ///     `shutdown()` returned `Void`, so the SIGTERM handler called `exit(0)`
    ///     on a failed revert — after cancelling the tick that was supposed to
    ///     retry it. All four produced the same state: fans physically forced
    ///     while `config.mode == .auto`, which by construction disarms the
    ///     watchdog, the temperature ceiling and all three guardian filters.
    ///
    ///     **The XPC surface is byte-identical.** The bump is here because a v26
    ///     daemon behind a v27 app still strands the fans on every one of those
    ///     paths, and nothing on the app side can see that it did — which is the
    ///     exact shape `docs/RELEASING.md` wrote this rule for.
    public static let protocolVersion = "27"
    /// How often the app sends a heartbeat while connected.
    public static let heartbeatInterval: TimeInterval = 5
    /// SAFETY: no heartbeat for this long → the daemon's watchdog reverts to
    /// auto (always in manual mode; in curve mode unless persistence is on).
    public static let watchdogTimeout: TimeInterval = 15
    /// The daemon's control/safety tick.
    public static let tickInterval: TimeInterval = 2

    /// SAFETY: how many times SIGTERM handling retries the hand-back before it
    /// gives up and exits non-zero.
    ///
    /// `shutdown()` cancels the safety tick, which is the thing that would
    /// otherwise retry a failed revert — so if the first attempt does not land,
    /// this loop is the only retry there is. The budget must stay inside the
    /// `ExitTimeOut` declared in `io.github.thijsvos.icecube.helper.plist`, and
    /// it does: four attempts, each bounded by `revertEverything`'s own three
    /// 200 ms read retries, separated by ``shutdownRevertRetryDelay``.
    public static let shutdownRevertAttempts = 4
    /// Pause between the hand-back retries above.
    public static let shutdownRevertRetryDelay: TimeInterval = 0.5

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
        // ICECUBE_SIMULATED belongs here for the same reason the test vars do:
        // a simulated run writes lines like "curve engaged" into the SAME
        // subsystem a real investigation greps, and this project has already
        // lost time to exactly that confusion.
        let underTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
            || environment["ICECUBE_SIMULATED"] == "1"
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
    /// The clamped per-fan targets the daemon last actually wrote — in curve
    /// mode as well as manual, since the curve tick fills this in with what it
    /// commanded, and every revert empties it.
    ///
    /// The app happens to read it only while `mode == .manual`
    /// (`PresetHighlight.reconcile`), which is why nobody noticed it has been
    /// carrying curve targets all along. Documented as manual-only until
    /// 2026-08-16; a field described narrower than it is, is how the next
    /// consumer gets it wrong.
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

    /// The same decisions as ``recentEvents``, timestamped and classified.
    ///
    /// Carried alongside the strings rather than replacing them: `recentEvents`
    /// is asserted in ~34 places across `DaemonCoreTests`, and the point of this
    /// addition is that none of those had to change.
    ///
    /// **Optional on purpose**, for the same reason ``activeCurve`` is: a
    /// missing key decodes to nil, so a peer that predates this field still
    /// decodes. A new non-optional key here would fail the whole status decode
    /// against a mismatched helper — which the app treats as a dead connection.
    public var recentDecisions: [DecisionEvent]?

    public init(
        protocolVersion: String = HelperConstants.protocolVersion,
        mode: FanConfig.Mode = .auto,
        appliedTargets: [Int: Double] = [:],
        unlockBranch: String? = nil,
        lastWriteVerified: Bool = false,
        guardianActive: Bool = false,
        recentEvents: [String] = [],
        activeCurve: FanCurve? = nil,
        recentDecisions: [DecisionEvent]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.mode = mode
        self.appliedTargets = appliedTargets
        self.unlockBranch = unlockBranch
        self.lastWriteVerified = lastWriteVerified
        self.guardianActive = guardianActive
        self.recentEvents = recentEvents
        self.activeCurve = activeCurve
        self.recentDecisions = recentDecisions
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
