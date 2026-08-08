// SMCReadPort.swift — the read-only SMC surface, so the provider's decisions can be tested without a Mac.

import Foundation

/// The seven calls `SystemSMCProvider` makes against the SMC.
///
/// The read-side twin of ``SMCControlPort``, and it exists for exactly the same
/// reason that one does: **the decisions above the syscalls are worth testing,
/// and the syscalls are not.**
///
/// ## Why this was missing for so long
///
/// `SystemSMCProvider` held a concrete `SMCConnection` — an actor that opens
/// `AppleSMC` in its initialiser — so there was no way to construct the
/// provider without real hardware, and no way to reach the ~140 lines of
/// decision logic sitting on top: the power-key resolution that requires a key
/// to both exist *and* read plausibly, the `.smcKeyNotFound`-is-an-answer rule
/// in discovery, the mode-key casing probe, the per-key degradation in
/// `fans()`, and the exhaustive type switch in `keyDump()`.
///
/// The project recorded this in PR #62 as *"reaching their ~130 pure lines
/// needs a read-side seam, which is a refactor not a test"*, and declined it.
/// That was a fair call at the time. It is also fifteen lines, and the daemon
/// has had the equivalent since the day `SensorReader` was written — which is
/// precisely why `SensorReader` is testable and this was not. So this is a
/// consistency fix as much as a testability one.
///
/// Deliberately **read-only**. The capability boundary is unchanged: there is
/// no write method here, `SMCConnection` has never had one, and
/// `scripts/verify-bundle.sh` still proves with `nm` that no writer reaches the
/// app binary.
public protocol SMCReadPort: Sendable {
    func keyInfo(for key: String) async throws(IceCubeError) -> SMCConnection.KeyInfo
    func hasKey(_ key: String) async -> Bool
    func readBytes(_ key: String) async throws(IceCubeError) -> (bytes: [UInt8], info: SMCConnection.KeyInfo)
    func readDouble(_ key: String) async throws(IceCubeError) -> Double
    func readString(_ key: String) async throws(IceCubeError) -> String
    func keyCount() async throws(IceCubeError) -> Int
    func key(atIndex index: Int) async throws(IceCubeError) -> String
}

/// The real thing already has this shape, so conformance is a declaration and
/// nothing more — no shim, no wrapper, no behaviour to keep in sync.
extension SMCConnection: SMCReadPort {}
