// SystemPowerWatcher.swift — IOKit root-power-domain registration: park the fans before sleep, tell the core on wake.

import Foundation
import IceCubeKit
import IOKit
import IOKit.pwr_mgt
import os

/// Turns the root power domain's C callback into two calls on ``DaemonCore``.
///
/// Deliberately dumb, and it lives in this target for the same reason
/// `SMCWritePort` does: this is raw IOKit and the app must never link it. Every
/// decision about WHAT to do to the fans is in `DaemonCore`/`SleepLatch` over in
/// IceCubeKit, where it is unit-tested against a scripted fake firmware. This
/// file owns only the mach port, the run-loop source, and the acknowledgement.
///
/// `@unchecked Sendable`: the IOKit handles are written once in ``start()`` on
/// the main run loop and only read afterwards, and the one piece of genuinely
/// shared state (the ack flag) carries its own lock.
final class SystemPowerWatcher: @unchecked Sendable {
    private let core: DaemonCore
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "smc")
    private var connection: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Off the Swift cooperative pool on purpose: the ack deadline must fire
    /// even if `DaemonCore` is wedged inside a blocking
    /// `IOConnectCallStructMethod`, which occupies a pool thread. A timer that
    /// exists to survive a wedged SMC must not share threads with it.
    private let ackQueue = DispatchQueue(label: "io.github.thijsvos.icecube.helper.power")

    init(core: DaemonCore) {
        self.core = core
    }

    /// Needs a live CFRunLoop — `main.swift`'s `RunLoop.main.run()` is the one
    /// the daemon has, and `CFRunLoopGetMain()` is that same loop.
    @discardableResult
    func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // The callback is a C function pointer, so it cannot capture: `self`
        // travels as the refcon and comes back through `Unmanaged.fromOpaque`.
        // Safe because `main.swift` holds this object for the process lifetime.
        connection = IORegisterForSystemPower(refcon, &notificationPort, { refcon, _, type, argument in
            guard let refcon else { return }
            Unmanaged<SystemPowerWatcher>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handle(message: type, argument: argument)
        }, &notifier)
        guard connection != MACH_PORT_NULL, let notificationPort else {
            log.fault("could not register for system power — the fans will NOT be handed back before sleep")
            return false
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
            .commonModes
        )
        log.notice("registered for system power notifications")
        return true
    }

    private func handle(message: UInt32, argument: UnsafeMutableRawPointer?) {
        // The argument IS the acknowledgement token, not a pointer to one.
        let notificationID = Int(bitPattern: argument)
        switch message {
        case SystemPowerMessage.canSystemSleep:
            // Never `IOCancelPowerChange`. A fan daemon must never be the reason
            // a Mac stays awake — and this does not fire for a lid close anyway.
            IOAllowPowerChange(connection, notificationID)
        case SystemPowerMessage.systemWillSleep:
            parkThenAcknowledge(notificationID)
        case SystemPowerMessage.systemHasPoweredOn:
            // Must NOT be acknowledged (IOPMLib).
            let core = core
            Task { await core.systemDidPowerOn() }
        default:
            // WillPowerOn / WillNotSleep / anything Apple adds later: IOPMLib
            // says these must NOT be acknowledged. Silence is the contract.
            break
        }
    }

    /// Hands the fans back, then acknowledges — but acknowledges no later than
    /// ``SleepPolicy/acknowledgementBudget``, whatever the SMC is doing.
    ///
    /// SAFETY, three separate promises:
    /// 1. IOKit is acknowledged **exactly once**. Twice for one notification is
    ///    an API violation; zero blocks the user's sleep for 30 s and gets Ice
    ///    Cube named in `pmset -g log`'s "Delays to Sleep notifications" — a far
    ///    more visible bug than the one being fixed.
    /// 2. The ack **never waits on the actor**, because the deadline lives on
    ///    its own dispatch queue.
    /// 3. A failed or slow park costs a few seconds of lid-close latency and a
    ///    `SAFETY:` line — never a hung sleep, never a veto.
    private func parkThenAcknowledge(_ notificationID: Int) {
        let acknowledged = OSAllocatedUnfairLock(initialState: false)
        let connection = connection
        let log = log

        @Sendable func acknowledgeOnce(_ why: String) {
            let alreadyDone = acknowledged.withLock { done -> Bool in
                defer { done = true }
                return done
            }
            guard !alreadyDone else { return }
            log.notice("sleep acknowledged — \(why, privacy: .public)")
            IOAllowPowerChange(connection, notificationID)
        }

        ackQueue.asyncAfter(deadline: .now() + SleepPolicy.acknowledgementBudget) {
            acknowledgeOnce("park budget expired — the fans may still be forced")
        }
        let core = core
        Task {
            await core.prepareForSleep()
            acknowledgeOnce("fans parked")
        }
    }
}
