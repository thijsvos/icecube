// main.swift — IceCubeHelper entry point: start the daemon core, listen for XPC, revert on SIGTERM.

import Foundation
import IceCubeKit
import os

let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "xpc")

let core: DaemonCore
do {
    // The only IOKit writer in the system stays in this target; DaemonCore
    // itself lives in IceCubeKit behind `SMCControlPort` so its safety logic
    // is unit-testable against a scripted fake firmware.
    core = try DaemonCore(port: SMCWritePort(), store: ConfigStore())
} catch {
    // No SMC — nothing a fan daemon can do. Exit cleanly (never fatalError);
    // launchd owns our lifecycle and may retry later.
    log.fault("cannot open the SMC: \(error.localizedDescription, privacy: .public)")
    exit(1)
}

// Revert-to-auto on start + begin the 2 s safety tick.
Task { await core.start() }

// SIGTERM (launchd shutdown/unregister): leave fans on automatic — always.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    Task {
        await core.shutdown()
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
