// main.swift — IceCubeHelper entry point: start the daemon core, listen for XPC, revert on SIGTERM.

import Foundation
import IceCubeKit
import os

let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "xpc")

let core: DaemonCore
do {
    core = try DaemonCore()
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
listener.resume()

RunLoop.main.run()
