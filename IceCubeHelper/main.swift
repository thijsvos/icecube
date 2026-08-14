// main.swift — IceCubeHelper entry point: start the daemon core, listen for XPC, revert on SIGTERM.

import Foundation
import IceCubeKit
import os

let log = Logger(subsystem: HelperConstants.logSubsystem, category: "xpc")

let core: DaemonCore
do {
    // The only IOKit writer in the system stays in this target; DaemonCore
    // itself lives in IceCubeKit behind `SMCControlPort` so its safety logic
    // is unit-testable against a scripted fake firmware.
    core = try DaemonCore(
        port: SMCWritePort(), store: ConfigStore(), capabilities: { SystemCapabilityReader.current() }
    )
} catch {
    // No SMC — nothing a fan daemon can do. Exit cleanly (never fatalError);
    // launchd owns our lifecycle and may retry later.
    log.fault("cannot open the SMC: \(error.localizedDescription, privacy: .public)")
    exit(1)
}

/// The sleep half of the power contract (PLAN.md §3.4, §4.3.6). `F{i}Md = 1`
/// survives sleep on Apple Silicon and nothing of ours runs while the machine is
/// asleep, so without this the fans keep spinning for the whole closed-lid window
/// — 16 min 34 s in the owner's own log on 2026-07-27. Registered here because
/// `RunLoop.main.run()` below is the only CFRunLoop this daemon has, and BEFORE
/// `start()` so a `systemWillSleep` arriving during boot finds a handler.
let power = SystemPowerWatcher(core: core)
power.start()

// Revert-to-auto on start + begin the 2 s safety tick.
Task { await core.start() }

// SIGTERM (launchd shutdown/unregister): leave fans on automatic — always.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    Task {
        // SAFETY: a hand-back that did not land must not exit as though it had.
        //
        // `shutdown()` cancels the safety tick, so `revertEverything`'s usual
        // "set `revertPending`, the tick will retry" recovery has nothing left to
        // run it. This loop IS the retry. It matters most on the uninstall path:
        // `SMAppService.unregister()` SIGTERMs the daemon *and* removes the job,
        // so an `exit(0)` on a failed revert strands the fans at their last
        // target with every safety net gone and nothing that could relaunch us.
        var handedBack = await core.shutdown()
        var attempts = 1
        while !handedBack, attempts < HelperConstants.shutdownRevertAttempts {
            try? await Task.sleep(for: .seconds(HelperConstants.shutdownRevertRetryDelay))
            handedBack = await core.shutdown()
            attempts += 1
        }
        guard handedBack else {
            // Non-zero so launchd records it, and so `KeepAlive/SuccessfulExit`
            // brings us straight back to try again — `start()` reverts on boot.
            // A clean hand-back exits 0 and stays gone, which is what makes
            // "Turn Off Fan Control" an uninstall rather than a restart loop.
            log.fault(
                "shutdown could not hand the fans back after \(attempts, privacy: .public) attempts — exiting non-zero"
            )
            exit(1)
        }
        exit(0)
    }
}

sigterm.resume()

// The XPC front door (matches MachServices in the LaunchDaemons plist).
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let service = HelperService(core: core)
listener.delegate = service

// SECURITY: pin at the LISTENER, not just per-connection.
//
// `NSXPCConnection.setCodeSigningRequirement` only rejects a mismatched peer
// once a message arrives — the peer still reaches the delegate first, which
// installs an invalidation handler that reverts every fan to auto. Any
// unprivileged local process could therefore connect, get torn down, and drive
// the daemon out of manual/curve control; in a loop it pinned the Mac to macOS
// auto fan control permanently. The mach service lives in the system bootstrap
// namespace, so it is reachable by every process on the box.
//
// The listener-level requirement rejects a non-matching peer *before* consulting
// the delegate, so such a connection never gets a handler at all. Kept alongside
// the per-connection call in HelperService, which stays as defence in depth.
if let requirement = CodesignPinning.requirementForPeer(identifier: HelperConstants.appBundleID) {
    listener.setConnectionCodeSigningRequirement(requirement)
    log.notice("listener pinned: \(requirement, privacy: .public)")
} else {
    // Unsigned helper: pinning is impossible. HelperService decides what that
    // means per build configuration (release rejects everything).
    log.fault("helper is unsigned — no listener-level pinning available")
}

listener.resume()

RunLoop.main.run()
