// PowerSourceMonitor.swift — tells the app when the Mac is unplugged or plugged back in.

import Foundation
import IceCubeKit
import IOKit.ps
import os

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
    /// Whether the battery is actually taking charge right now. Read fresh, as
    /// ``current`` is.
    ///
    /// Separate from ``current`` because `.wall` cannot answer it: plugged in
    /// and filling, and plugged in and long since full, are the same case to
    /// that property — and only the first turns watts into heat. Charging also
    /// stops without any source transition, so ``onChange`` could not carry
    /// this even if it were folded in.
    var isCharging: Bool { get }
    /// Called on the main actor the moment IOKit reports a change, so a rule
    /// can act immediately instead of waiting for the next poll.
    ///
    /// Optional in the honest sense: whoever sets it must ALSO keep polling
    /// ``current``, because nothing guarantees this fires. See
    /// ``PowerSourceMonitor`` for why that is not paranoia.
    var onChange: (@MainActor () -> Void)? { get set }
    /// Begins observing. Safe to call more than once.
    func start()
}

// No default implementations here, deliberately. There were — `onChange`
// returning nil with a no-op setter, and an empty `start()` — and all three
// conformers already implemented both, so the defaults could never run. What
// they could do is absorb a fourth conformer that forgot one: a power monitor
// that silently never starts, or that accepts an `onChange` and drops it, with
// the compiler saying nothing. `HelperManager` sets `onChange` and calls
// `start()` on this seam, so both silences are load-bearing failures.

/// The real thing: IOKit notifications for speed, with the app's existing 5 s
/// poll underneath as a guarantee.
///
/// **Both, deliberately.** The first version of this feature used only
/// `IOPSNotificationCreateRunLoopSource`, and on hardware it delivered nothing
/// at all — plugging and unplugging produced no callback, no log line and no
/// switch. It was replaced with pure polling, which works but takes up to five
/// seconds to notice a charger.
///
/// So the notification is back for the fast path, and the poll stays as the
/// floor. That is not indecision: a notification makes the common case
/// instant, and a poll makes the worst case bounded. Relying on the callback
/// alone is what failed, and dropping it means never being faster than the
/// tick. ``PowerProfilePolicy`` is transition-based, so both paths asking the
/// same question is inert by construction — whichever notices first wins, and
/// the other finds nothing to do.
///
/// Every path logs. The reason the original failure was so hard to place is
/// that it was silent: there was no way to tell whether the run-loop source
/// failed to create, the callback was never invoked, or the read was wrong.
final class PowerSourceMonitor: PowerSourceObserving {
    var onChange: (@MainActor () -> Void)?
    /// `nonisolated(unsafe)` only so `deinit` may read it. Everything else
    /// touches it from the main actor, and `deinit` runs when nothing else holds
    /// a reference at all — so there is no concurrent access to be unsafe about.
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "xpc")

    var current: PowerProfilePolicy.PowerSource {
        Self.read().source
    }

    var isCharging: Bool {
        Self.read().isCharging
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>
                .fromOpaque(context).takeUnretainedValue()
            // Hop rather than assume. The callback's thread is IOKit's to
            // choose, and `MainActor.assumeIsolated` would trap the app rather
            // than merely miss an event if that choice were ever not main.
            Task { @MainActor in monitor.notified() }
        }, context) else {
            // Not fatal — the poll still catches everything within 5 s — but it
            // must not be invisible, because this is exactly where the first
            // implementation failed without saying so.
            log.error("power: IOKit refused a notification source; falling back to the 5 s poll")
            return
        }
        let source = unmanaged.takeRetainedValue()
        runLoopSource = source
        // `.commonModes`, not `.defaultMode`: a menu-bar app spends much of its
        // life with the run loop in tracking mode (the popover open, a menu
        // down), and a source registered only for the default mode is silent
        // for all of it. The prime suspect for the original silence.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        log.notice("power: watching for charger changes (poll backstop every 5 s)")
    }

    private func notified() {
        log.notice("power: IOKit reported a change")
        onChange?()
    }

    deinit {
        // The callback holds an *unretained* pointer back to this object, so the
        // source has to go before the object does. In the app this never runs —
        // the monitor lives as long as `HelperManager` — but a test that builds
        // and drops one would otherwise arm a dangling callback.
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    /// What one pass over the power-source list yields.
    ///
    /// Both facts come from the same `IOPSGetPowerSourceDescription`
    /// dictionary, which this function already built and previously read a
    /// single key from. `kIOPSIsChargingKey` is a second subscript on a value
    /// held in hand — no extra IOKit call, no entitlement, nothing new linked.
    struct Reading {
        var source: PowerProfilePolicy.PowerSource = .wall
        var isCharging = false
    }

    /// Reads the current source.
    ///
    /// Defaults to `.wall` when IOKit reports nothing usable — a desktop Mac
    /// has no battery at all, and that is the honest answer for one, not a
    /// failure. It also means a machine that cannot be unplugged never sees a
    /// transition, so the rule simply never fires there.
    private static func read() -> Reading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
              as? [CFTypeRef]
        else { return Reading() }

        var reading = Reading()
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            // Charging is read from every source rather than only the one that
            // decides `.battery`, because a Mac on wall power reports
            // `kIOPSACPowerValue` and is precisely the case worth catching.
            if description[kIOPSIsChargingKey] as? Bool == true {
                reading.isCharging = true
            }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue {
                reading.source = .battery
            }
        }
        return reading
    }
}
