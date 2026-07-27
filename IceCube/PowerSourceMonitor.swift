// PowerSourceMonitor.swift — tells the app when the Mac is unplugged or plugged back in.

import Foundation
import IceCubeKit
import IOKit.ps

/// Reports where the Mac is drawing power, and calls back when that changes.
///
/// Extracted as a protocol for the same reason as ``HelperChanneling``: the
/// interesting behaviour is what happens *on a transition*, and a test cannot
/// unplug a Mac. A fake drives both directions in microseconds, so CI never
/// depends on the runner's power state — which on a rack-mounted build machine
/// is permanently `wall` and would exercise nothing.
protocol PowerSourceObserving: AnyObject {
    /// Where the Mac is drawing power right now. Read fresh on each call.
    var current: PowerProfilePolicy.PowerSource { get }
}

/// The real thing: a fresh IOKit read, polled by the app's existing 5 s
/// maintenance pass.
///
/// **Polled, not notified, after the notification version silently never
/// fired.** The first implementation used
/// `IOPSNotificationCreateRunLoopSource` with a C callback added to the main
/// run loop. It built, it ran, and on hardware it delivered nothing at all —
/// unplugging and replugging produced no log line and no switch. It also had no
/// logging of its own, so there was no way to tell whether the source had failed
/// to create, the callback was never invoked, or the read was wrong.
///
/// Polling makes all of that moot. ``HelperManager`` already wakes every 5 s to
/// feed the daemon's watchdog, reading this is a couple of microseconds, and
/// ``PowerProfilePolicy`` is transition-based by design — so asking it the same
/// question repeatedly is inert by construction, not by luck. Detecting a
/// charger within five seconds is not a feature anyone will miss, and a
/// mechanism that demonstrably works beats a more elegant one that does not.
final class PowerSourceMonitor: PowerSourceObserving {
    var current: PowerProfilePolicy.PowerSource {
        Self.read()
    }

    /// Reads the current source.
    ///
    /// Defaults to `.wall` when IOKit reports nothing usable — a desktop Mac
    /// has no battery at all, and that is the honest answer for one, not a
    /// failure. It also means a machine that cannot be unplugged never sees a
    /// transition, so the rule simply never fires there.
    private static func read() -> PowerProfilePolicy.PowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
              as? [CFTypeRef]
        else { return .wall }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue {
                return .battery
            }
        }
        return .wall
    }
}
