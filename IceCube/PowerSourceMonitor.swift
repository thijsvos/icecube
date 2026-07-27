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
    var current: PowerProfilePolicy.PowerSource { get }
    /// Called on the main actor when the source changes.
    var onChange: ((PowerProfilePolicy.PowerSource) -> Void)? { get set }
    /// Begins observing. Separate from init, like ``HelperManager/start()``,
    /// so constructing one has no side effects.
    func start()
}

/// The real thing: IOKit's power-source notifications.
///
/// `IOPSNotificationCreateRunLoopSource` fires on any power change — including
/// battery percentage ticks, which arrive every few seconds — so this collapses
/// them to the only distinction Ice Cube cares about and reports nothing unless
/// AC-vs-battery actually flipped. Without that filter the policy would be
/// asked to decide dozens of times an hour, and every one of those is a chance
/// for a bug to become an override.
final class PowerSourceMonitor: PowerSourceObserving {
    private(set) var current: PowerProfilePolicy.PowerSource
    var onChange: ((PowerProfilePolicy.PowerSource) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    init() {
        current = Self.read()
    }

    // No `deinit` teardown on purpose. `CFRunLoopSource` is not `Sendable` and
    // `deinit` is nonisolated, so Swift 6 refuses to touch it there — and
    // working around that would be for a case that does not exist: exactly one
    // monitor is created, it is owned by the app-lifetime `HelperManager`, and
    // the run loop dies with the process. Tests inject a fake and never build
    // this at all.

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context)
                .takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Re-reads and reports only a genuine AC-vs-battery flip.
    private func refresh() {
        let now = Self.read()
        guard now != current else { return }
        current = now
        onChange?(now)
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
