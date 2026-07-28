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
    /// The design ASSUMES this is not delivered on a dark wake, but neither
    /// `<IOKit/IOMessage.h>` nor `<IOKit/pwr_mgt/IOPMLib.h>` says so — they are
    /// silent on Dark Wake for every one of these messages. The owner's
    /// `pmset -g log` does distinguish them (`DarkWake … [CDNP]` versus
    /// `Wake … [CDNVA]`), which is suggestive, not documentation. ``SleepLatch``
    /// is therefore written to stay correct if it DOES fire on a dark wake:
    /// each spurious unpark costs one re-engage and is undone by the next
    /// `systemWillSleep`.
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
