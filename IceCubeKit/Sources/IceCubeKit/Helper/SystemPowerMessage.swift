// SystemPowerMessage.swift — the kIOMessage* values Swift cannot import, plus the budget the sleep park promises IOKit.

import Foundation

/// The root-power-domain messages `IORegisterForSystemPower` delivers.
///
/// Declared by hand because they are **C macros**, not constants:
/// `#define kIOMessageSystemWillSleep iokit_common_msg(0x280)`, where
/// `iokit_common_msg(x) = sys_iokit | sub_iokit_common | x = 0xE0000000 | x`.
/// Swift reports "macro unavailable: structure not supported", which stops an
/// implementer cold — hence this table, and hence ``SystemPowerMessageTests``
/// pinning each value against that derivation. Every value below was read out
/// of `<IOKit/IOMessage.h>` by a C probe on this Mac14,9, not guessed.
///
/// No IOKit import here on purpose: IceCubeKit is linked into the unprivileged
/// app, and the only file that may touch the power API is
/// `IceCubeHelper/SystemPowerWatcher.swift`.
public enum SystemPowerMessage {
    /// An *idle* sleep is being proposed and may be vetoed. Ice Cube never
    /// vetoes — and this message is **not** sent for a lid close, because a
    /// clamshell sleep is forced and skips the veto round entirely. Implementing
    /// only this one would test fine on an idle timeout and still fail on the
    /// exact gesture the owner reported.
    public static let canSystemSleep: UInt32 = 0xE000_0270
    /// Non-abortable sleep, delivered **before any hardware is powered off** —
    /// the last moment an SMC write can land. MUST be acknowledged.
    public static let systemWillSleep: UInt32 = 0xE000_0280
    /// A vetoed idle sleep. Must NOT be acknowledged.
    public static let systemWillNotSleep: UInt32 = 0xE000_0290
    /// Fully awake. Must NOT be acknowledged.
    ///
    /// SETTLED BY FIELD EVIDENCE, 2026-07-31. Neither `<IOKit/IOMessage.h>` nor
    /// `<IOKit/pwr_mgt/IOPMLib.h>` says whether this arrives on a dark wake;
    /// the owner's log now does. Across every wake the daemon logged, all five
    /// `wake: resuming … (the system powered on)` lines line up with a
    /// `[CDNVA]`/`[CDNVAP]` full wake — including three `DarkWake to FullWake`
    /// promotions, so the message tracks the *promotion*, not the dark wake
    /// underneath it — and no pure `DarkWake … [CDNP]` ever produced one. The
    /// assumption held.
    ///
    /// What did NOT hold was the sibling assumption in `DaemonCore.parkedTick`,
    /// that an app heartbeat cannot arrive during a dark wake: three did, and
    /// one of them (00:31:53, inside a `[CDNPB]` rtc/Maintenance dark wake with
    /// the lid shut) unparked the daemon and drove both fans to 6800 RPM for
    /// 69 seconds. The daemon therefore no longer trusts ANY message or
    /// heartbeat as proof of a real wake: ``DaemonCore`` requires a positive
    /// ``PowerCapabilities`` read showing a powered display before the sleep
    /// latch may drop. This message is now only the *edge* — "a wake began" —
    /// and stays useful precisely because it is no longer the whole answer.
    public static let systemHasPoweredOn: UInt32 = 0xE000_0300
    /// Wake is starting; disks and network may not answer. Must NOT be acked.
    public static let systemWillPowerOn: UInt32 = 0xE000_0320
}

/// Timing the daemon promises the power manager.
public enum SleepPolicy {
    /// How long the daemon may spend parking the fans before it acknowledges
    /// the sleep regardless.
    ///
    /// IOKit's own cap is 30 s, after which the sleep proceeds anyway and the
    /// app is named in `pmset -g log`'s "Delays to Sleep notifications". We
    /// self-impose far less: the measured hand-back on the owner's Mac14,9 took
    /// **282 ms** (`18:38:20.863 SAFETY: reverting…` → `18:38:21.145 all fans
    /// auto`), so 6 s is twenty times the real cost and still a fifth of the
    /// cap. Past it we acknowledge and log — a wedged SMC costs a few seconds
    /// of lid-close latency, never a hung sleep, and never a veto.
    public static let acknowledgementBudget: TimeInterval = 6
}
