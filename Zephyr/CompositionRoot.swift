// CompositionRoot.swift — the one place that decides which SMC provider the app runs against.

import Foundation
import os
import ZephyrKit

/// Builds the app's object graph. Nothing else in the app may construct a
/// provider — keeping the choice in one place is what lets tests, CI, and
/// Phase 1 swap implementations without touching UI code.
enum CompositionRoot {
    /// Picks the SMC provider for this launch.
    ///
    /// Simulated mode is on when the `ZEPHYR_SIMULATED` environment variable
    /// is `"1"` (the committed "Zephyr (Simulated)" scheme sets it) or when
    /// `--simulated` was passed on the command line.
    ///
    /// Phase 0: both branches return `MockSMCProvider` because real SMC reads
    /// (`SystemSMCProvider`) arrive in Phase 1 — the non-simulated branch says
    /// so out loud in the log. Phase 1 changes exactly one line, marked below.
    static func make() -> (provider: any SMCProviding, isSimulated: Bool) {
        let simulated = ProcessInfo.processInfo.environment["ZEPHYR_SIMULATED"] == "1"
            || CommandLine.arguments.contains("--simulated")

        if simulated {
            return (provider: MockSMCProvider(), isSimulated: true)
        }

        let logger = Logger(subsystem: "io.github.thijsvos.zephyr", category: "smc")
        logger.notice("Real SMC reads are not implemented yet (Phase 1) — falling back to the simulated provider.")
        // PHASE 1: replace MockSMCProvider() with SystemSMCProvider() on the
        // next line and return isSimulated: false. Until then the data IS
        // simulated, so the badge must say so even without the flag.
        return (provider: MockSMCProvider(), isSimulated: true)
    }
}
