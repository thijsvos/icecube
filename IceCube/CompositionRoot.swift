// CompositionRoot.swift — the one place that decides which SMC provider the app runs against.

import Foundation
import IceCubeKit
import os

/// Builds the app's object graph. Nothing else in the app may construct a
/// provider — keeping the choice in one place is what lets tests, CI, and
/// Phase 1 swap implementations without touching UI code.
enum CompositionRoot {
    /// Picks the SMC provider for this launch.
    ///
    /// Simulated mode is on when the `ICECUBE_SIMULATED` environment variable
    /// is `"1"` (the committed "Ice Cube (Simulated)" scheme sets it) or when
    /// `--simulated` was passed on the command line. Otherwise the app opens
    /// the real SMC read-only; if that fails (no AppleSMC service — not a
    /// Mac?) it falls back to the simulation rather than launching dead, and
    /// the SIMULATED badge tells the truth about what's on screen.
    static func make() -> (provider: any SMCProviding, isSimulated: Bool) {
        let simulated = ProcessInfo.processInfo.environment["ICECUBE_SIMULATED"] == "1"
            || CommandLine.arguments.contains("--simulated")

        if simulated {
            return (provider: MockSMCProvider(), isSimulated: true)
        }

        do {
            return try (provider: SystemSMCProvider(), isSimulated: false)
        } catch {
            Logger(subsystem: "io.github.thijsvos.icecube", category: "smc")
                .error("Cannot open the SMC (\(error.localizedDescription)) — falling back to the simulated provider.")
            return (provider: MockSMCProvider(), isSimulated: true)
        }
    }
}
