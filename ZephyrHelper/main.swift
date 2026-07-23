// main.swift — ZephyrHelper Phase 0 stub: log one startup line, then idle. No SMC access, no XPC yet.

import Foundation
import os
import ZephyrKit

// The privileged helper daemon. In later phases this process owns ALL SMC
// writes (clamped, watchdogged, audited) behind an XPC service. In Phase 0 it
// only proves the target builds, links ZephyrKit, and can be launched.
//
// Daemon rule from day one: never `fatalError` — a crash-looping root daemon
// is worse than a dead one. This stub has no failure paths at all.

let logger = Logger(subsystem: "io.github.thijsvos.zephyr", category: "xpc")

/// Bumped by hand until Phase 6 wires real versioning.
let helperVersion = "0.1.0"

// Referencing FanConfig.auto proves the ZephyrKit linkage end to end: if the
// Kit is missing from the helper target, this line fails to compile.
logger
    .notice(
        "ZephyrHelper started (Phase 0 stub — no SMC access, no XPC yet) version \(helperVersion, privacy: .public), default config mode: \(FanConfig.auto.mode.rawValue, privacy: .public)"
    )

// Park the main thread forever; launchd owns our lifecycle and will send
// SIGTERM when the daemon should exit.
RunLoop.main.run()
