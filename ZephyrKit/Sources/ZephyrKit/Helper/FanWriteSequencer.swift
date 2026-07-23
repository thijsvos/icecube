// FanWriteSequencer.swift — the generation-aware Apple Silicon fan write state machine (clamp → unlock → write →
// verify).

import Foundation

/// Which unlock path this machine's firmware needed (PLAN.md §3.2).
public enum UnlockBranch: String, Sendable, Equatable {
    /// Mode write accepted directly (M1/M2 behavior; also M5).
    case direct
    /// Firmware rejected the mode write (result 0x82) until `Ftst=1` made
    /// `thermalmonitord` yield (M3/M4 behavior). Experimental until
    /// community-verified — the owner's M2 Pro cannot exercise it.
    case ftst
}

/// The result of one manual-engage sequence.
public struct FanWriteOutcome: Sendable, Equatable {
    public let branch: UnlockBranch
    /// The targets actually written, after clamping to each fan's range.
    public let clampedTargets: [Int: Double]
    /// Read-back verification: mode stuck at 1 and Tg equals the command.
    public let verified: Bool
}

/// Drives the SMC write sequence for manual fan control, per PLAN.md §3.2:
/// probe mode-key casing (`F{i}Md` vs `F{i}md`) → clamp targets → try the
/// direct mode write → on firmware rejection 0x82, write `Ftst=1`, wait for
/// `thermalmonitord` to yield, retry ≤ 10 s → write `F{i}Tg` (float32) →
/// **verify by read-back**. Revert = mode 0 per fan, then `Ftst=0`.
///
/// SAFETY: clamping happens here, daemon-side, on SMC-reported `[Mn, Mx]` —
/// the firmware itself treats those as advisory (0 RPM can be accepted), so
/// this clamp is the only real guard. The sequencer is pure over
/// ``SMCControlPort`` with injected sleep, so every branch is unit-tested.
public actor FanWriteSequencer {
    private let port: any SMCControlPort
    /// Injected so tests run instantly; the daemon passes real Task.sleep.
    private let sleep: @Sendable (Duration) async -> Void

    /// Probed once per machine: `"Md"` or `"md"` (M5 renamed the key).
    private var modeKeySuffix: String?
    /// Remembered after the first successful engage.
    public private(set) var knownBranch: UnlockBranch?

    /// Retry cadence and budget for the Ftst path (per exelban/stats).
    static let ftstSettleDelay = Duration.seconds(3)
    static let ftstRetryInterval = Duration.milliseconds(100)
    static let ftstRetryLimit = 70 // ≈ 7 s of retries after the settle delay

    public init(
        port: any SMCControlPort,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.sleep = sleep
    }

    // MARK: - Engage manual mode

    /// Clamps `targets` to each fan's reported range, forces manual mode via
    /// the correct per-generation sequence, writes the targets, and verifies
    /// by read-back.
    ///
    /// - Parameter fans: the current fan readings (source of `[Mn, Mx]`).
    /// - Throws: when no mode key exists, the unlock never sticks, or a write
    ///   fails at the transport level. The caller (daemon) reverts on throw.
    public func engageManual(targets: [Int: Double], fans: [Fan]) async throws -> FanWriteOutcome {
        let suffix = try await resolveModeKeySuffix(fanIDs: fans.map(\.id))
        var clamped: [Int: Double] = [:]
        var branch: UnlockBranch = knownBranch ?? .direct
        var allVerified = true

        for fan in fans {
            guard let requested = targets[fan.id] else { continue }
            let target = Self.clamp(requested, to: fan)
            clamped[fan.id] = target
            let modeKey = "F\(fan.id)\(suffix)"

            branch = try await forceManualMode(modeKey: modeKey, preferring: branch)
            try await port.writeDouble("F\(fan.id)Tg", value: target, as: .float)

            // Read-back: the firmware can silently ignore writes; §3.2 makes
            // verification mandatory, not optional.
            let modeBack = try await port.readDouble(modeKey)
            let tgBack = try await port.readDouble("F\(fan.id)Tg")
            if modeBack != Double(FanMode.forced.rawValue) || abs(tgBack - target) > 1 {
                allVerified = false
            }
        }
        knownBranch = branch
        return FanWriteOutcome(branch: branch, clampedTargets: clamped, verified: allVerified)
    }

    /// Reverts every fan to automatic: mode 0 (+ Tg 0), then `Ftst=0` once
    /// all fans are back on auto (only if the Ftst path was used).
    ///
    /// FIELD CORRECTION (2026-07-23, verified on Mac14,9 / macOS 26.4.1):
    /// the reference sequence "mode 0 + Tg 0" left the fans **stopped at
    /// 0 RPM** — thermalmonitord did not reclaim them. Writing target 0 is
    /// exactly the unsafe command our clamp forbids the *app* from sending,
    /// so the revert must never send it either. The safe hand-back:
    /// park `Tg` at the fan's minimum FIRST (if the firmware keeps honoring
    /// it, the floor spins — never silence), then mode 0, then attempt mode 3
    /// (explicitly returning the fan to macOS; some generations refuse, which
    /// is fine). `DaemonCore` adds a tick-level safety net on top.
    public func revertAllAuto(fans: [Fan]) async throws {
        guard let suffix = try? await resolveModeKeySuffix(fanIDs: fans.map(\.id)) else { return }
        for fan in fans {
            if fan.minRPM > 0 {
                try? await port.writeDouble("F\(fan.id)Tg", value: fan.minRPM, as: .float)
            }
            try await port.writeDouble("F\(fan.id)\(suffix)", value: 0, as: .uint8)
            try? await port.writeDouble("F\(fan.id)\(suffix)", value: 3, as: .uint8)
        }
        if knownBranch == .ftst, await port.hasKey("Ftst") {
            try await port.writeDouble("Ftst", value: 0, as: .uint8)
        }
    }

    // MARK: - The unlock state machine

    /// Writes mode 1 to `modeKey`, escalating to the Ftst unlock on firmware
    /// rejection 0x82. Returns the branch that worked.
    private func forceManualMode(modeKey: String, preferring: UnlockBranch) async throws -> UnlockBranch {
        do {
            try await port.writeDouble(modeKey, value: 1, as: .uint8)
            return preferring == .ftst ? .ftst : .direct
        } catch let ZephyrError.smcFirmwareRejected(_, result) where result == SMCResult.badCommand {
            // thermalmonitord holds mode 3 (M3/M4): unlock and retry.
            guard await port.hasKey("Ftst") else {
                throw ZephyrError.smcFirmwareRejected(key: modeKey, result: result)
            }
            try await port.writeDouble("Ftst", value: 1, as: .uint8)
            await sleep(Self.ftstSettleDelay)
            for _ in 0 ..< Self.ftstRetryLimit {
                do {
                    try await port.writeDouble(modeKey, value: 1, as: .uint8)
                    return .ftst
                } catch ZephyrError.smcFirmwareRejected {
                    await sleep(Self.ftstRetryInterval)
                }
            }
            throw ZephyrError.smcFirmwareRejected(key: modeKey, result: result)
        }
    }

    /// Determines whether this machine uses `F{i}Md` or `F{i}md` (cached).
    private func resolveModeKeySuffix(fanIDs: [Int]) async throws -> String {
        if let modeKeySuffix {
            return modeKeySuffix
        }
        guard let probe = fanIDs.min() else {
            throw ZephyrError.smcKeyNotFound(key: "FNum")
        }
        for suffix in ["Md", "md"] where await port.hasKey("F\(probe)\(suffix)") {
            modeKeySuffix = suffix
            return suffix
        }
        throw ZephyrError.smcKeyNotFound(key: "F\(probe)Md")
    }

    // MARK: - The clamp (the real guard — firmware limits are advisory)

    /// Clamps a requested RPM into the fan's reported `[minRPM, maxRPM]`.
    public static func clamp(_ requested: Double, to fan: Fan) -> Double {
        guard fan.maxRPM > fan.minRPM else { return fan.maxRPM }
        return Swift.min(Swift.max(requested, fan.minRPM), fan.maxRPM)
    }
}
