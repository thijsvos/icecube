// SensorReader.swift — the daemon's hardware reads: which sensors this Mac has, and what they say right now.

import Foundation

/// Everything the daemon reads from the SMC, and the admitted sensor set it
/// caches.
///
/// An `actor`, matching `FanWriteSequencer`, holding the same `SMCControlPort`.
/// It has **no write method**: the app-can't-write capability boundary is
/// unchanged, and `scripts/verify-bundle.sh` still proves it with `nm`.
///
/// **Why it left `DaemonCore`.** These are ~230 lines with one subject and one
/// piece of state — `sensorKeys`, the admitted set — that nothing else in the
/// daemon touches. Everything around them is policy: the watchdog, the ceiling,
/// the write sequencing, the sleep latch. Extracting them takes the state with
/// it, so **not one `private` member of `DaemonCore` had to widen** — which was
/// the whole constraint, and the reason the tempting `extension DaemonCore`
/// split was rejected twice before.
///
/// **The one design decision.** `readTemperatures` has three things to say, and
/// saying them means `DaemonCore.record`, which mutates `status.recentEvents`
/// on the daemon's actor. Calling back in would be a hop inside a read that
/// runs every 2 s, so the notices come back *with* the readings and the daemon
/// drains them at a single call site — which also preserves `recentEvents`
/// ordering exactly as it was when the reads and the logging shared an actor.
///
/// **`nil` readings mean blindness, and are NOT `[]`.** This is the one thing
/// the return type can plausibly get wrong. `SafetyMonitor` counts a nil read
/// as a failure and reverts after three consecutive ones, while an empty array
/// **resets** that counter — so returning `[]` for a blind tick would hold
/// manual control forever on a machine the daemon cannot see, with the ceiling
/// permanently inert because an empty set is never over any limit. That is
/// characterization rule 7, and `aTickWithNoUsableReadingIsBlindness` is the
/// test that catches it.
actor SensorReader {
    /// One tick's temperature read: the readings, or `nil` for blindness, plus
    /// whatever the read wants written to the daemon's event log.
    struct TemperatureRead: Sendable {
        let readings: [SensorReading]?
        let notices: [String]
    }

    private let port: any SMCControlPort
    private let sleep: @Sendable (Duration) async -> Void

    /// The admitted sensor set, resolved once and cached. `nil` means
    /// unresolved — never "this Mac has no sensors".
    private var sensorKeys: [String]?

    init(port: any SMCControlPort, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.port = port
        self.sleep = sleep
    }

    /// Matches `hottestDieRetrying()`: enough to ride out a connection reopen,
    /// short enough that a genuinely dead SMC still fails within one tick.
    private static let readRetries = 3

    /// Transport retries shared by one whole discovery pass. Three, matching
    /// ``readRetries``; bounded so probing the fallback superset on a dead
    /// connection costs milliseconds rather than most of a tick.
    private static let probeRetryBudget = 3

    // MARK: - Probing

    /// Whether this Mac HAS `key` — the daemon's half of ``SensorAdmission``.
    ///
    /// Deliberately NOT `port.hasKey`: that is `(try? keyInfo) != nil`, which
    /// collapses "the firmware says there is no such key" into the same `false`
    /// as "the call failed", and the empty-probe rule below exists precisely
    /// because those two are different facts — one is a property of the model,
    /// the other is a connection that `start()`'s `port.reset()` just closed.
    /// `hasKey` also reports no wire type, so it cannot refuse a key that
    /// exists but decodes to nothing; such a key would throw on every tick,
    /// count as missing on every tick, and re-trip the partial-failure re-probe
    /// forever. That is where the old dead-key loop hazard would have moved.
    ///
    /// One read answers both, in its error. **The value is discarded.** Looking
    /// at it is what made discovery a lottery.
    private func probeExists(_ key: String, retryBudget: inout Int) async -> Bool {
        while true {
            do {
                _ = try await port.readDouble(key)
                return true // it answered with a number; that is all we asked
            } catch IceCubeError.smcKeyNotFound {
                return false // a stable property of this model
            } catch IceCubeError.smcDecodingFailed {
                return false // exists, but carries no temperature we can decode
            } catch {
                // Transport failure: not an answer about the hardware. Retry —
                // the one thing a retry was ever good for here — and once the
                // budget is gone leave the key out and let the empty-probe and
                // die-sensor rules judge the truncated set. The next probe
                // reconsiders it.
                guard retryBudget > 0 else { return false }
                retryBudget -= 1
                await sleep(.milliseconds(60))
            }
        }
    }

    // MARK: - Fans

    /// Reads a key that this Mac may or may not have, retrying transient
    /// failures — the distinction the fan reads used to collapse.
    ///
    /// Returns nil ONLY when the firmware itself says the key does not exist
    /// (`SMCResult.keyNotFound`), which is a real per-machine difference worth
    /// tolerating. Every other failure is transport-level and gets retried, and
    /// if it still fails it is THROWN rather than turned into a number.
    ///
    /// That last part is the whole point. `readFans` used to swallow every
    /// failure with `(try? …) ?? 0`, so a fan whose mode read missed came back
    /// as `.system` with `targetRPM` 0 — which is bit-for-bit what "macOS took
    /// the fans off us" looks like. `verifyCurveHeld` believed it, logged a
    /// read-back mismatch and re-asserted; twice in a row and it would have
    /// reverted a perfectly healthy curve to auto and told the user it had lost
    /// control. Observed on a normal app restart, because `resetPort()` closes
    /// the connection and the first read after it is the one most likely to
    /// miss.
    private func readOptional(_ key: String) async throws -> Double? {
        for attempt in 0 ..< Self.readRetries {
            do {
                return try await port.readDouble(key)
            } catch IceCubeError.smcKeyNotFound {
                return nil // genuinely absent on this Mac — not a failure
            } catch {
                guard attempt < Self.readRetries - 1 else { throw error }
                await sleep(.milliseconds(60))
            }
        }
        return nil
    }

    /// Still `throws`, and still throws the same `IceCubeError` cases: `apply()`
    /// propagates the failure over XPC, where `WireError` renders it for the
    /// user. Every other caller uses `try?`.
    func readFans() async throws -> [Fan] {
        // `Int(someDouble)` traps on NaN/±inf and on anything past Int.max;
        // a garbage fan count must yield no fans, not a dead daemon.
        let rawCount = try await port.readDouble("FNum")
        let count = Int(exactly: rawCount.rounded(.towardZero)) ?? 0
        guard (0 ... 64).contains(count) else {
            throw IceCubeError.smcDecodingFailed(
                key: "FNum", type: "fan count", bytes: []
            )
        }
        var fans: [Fan] = []
        for i in 0 ..< count {
            // Only an ABSENT mode key means `.system`. A mode key that exists
            // but would not read now throws, so the caller skips this tick
            // rather than concluding we have lost the fans.
            let mode: FanMode = if let raw = try await readOptional("F\(i)Md") {
                FanMode(smcValue: raw)
            } else if let raw = try await readOptional("F\(i)md") {
                FanMode(smcValue: raw)
            } else {
                .system
            }
            try await fans.append(Fan(
                id: i,
                name: "Fan \(i)",
                mode: mode,
                actualRPM: readOptional("F\(i)Ac") ?? 0,
                targetRPM: readOptional("F\(i)Tg") ?? 0,
                minRPM: readOptional("F\(i)Mn") ?? 0,
                maxRPM: readOptional("F\(i)Mx") ?? 0
            ))
        }
        return fans
    }

    // MARK: - Temperatures

    func readTemperatures() async -> TemperatureRead {
        var notices: [String] = []
        if sensorKeys == nil {
            // Unmapped models fall back to probing the candidate superset
            // instead of resolving to nothing — an unknown Mac used to leave
            // the daemon permanently blind, which disables the ceiling and the
            // guardian while the app's UI still shows correct temperatures.
            let model = HostInfo.modelIdentifier()
            let candidates = SMCKeyMaps.curatedSensors(forModel: model)
                ?? SMCKeyMaps.fallbackCandidateSensors
            // Membership comes from key EXISTENCE, never from a reading — the
            // same rule the app side uses (`SensorAdmission`), for the same
            // measured reason. On Apple Silicon a power-gated CPU cluster
            // returns a frozen firmware sentinel (Mac14,9: exactly 6.70 °C and
            // 4.63 °C, a whole cluster at a time, P-cluster gated at 66.9 % of
            // idle instants), so admitting on a plausible read disowned every
            // P-core for the life of the daemon. The owner's daemon logged
            // `resolved 8 temperature sensors` — 8 of 20, its only silicon
            // input the two GPU dies, while the 104 °C die ceiling is the one
            // release allowed to spin fans inside a closed lid. Retrying cannot
            // fix it: an immediate retry recovered 0 of 18 misses, and so did
            // +5 ms and +50 ms, because the key is not failing — it is
            // answering with a lie. Gate episodes last 1.1–84.8 s; a 2 s tick
            // cannot wait one out.
            //
            // The probe is a READ WHOSE VALUE IS DISCARDED. `SMCControlPort`
            // has no key-info call and must not grow one, but `readDouble`
            // already answers the only two questions membership turns on, in
            // its error rather than its result — see `probeExists`.
            var existing: Set<String> = []
            existing.reserveCapacity(candidates.count)
            // ONE retry budget for the whole probe, not one per candidate: a
            // reopen after `port.reset()` is retried once, not forty times, and
            // a dead connection cannot spend the whole 2 s tick sleeping.
            var retryBudget = Self.probeRetryBudget
            for sensor in candidates where await probeExists(sensor.key, retryBudget: &retryBudget) {
                existing.insert(sensor.key)
            }
            let present = SensorAdmission
                .admit(candidates: candidates, presentKeys: existing)
                .map(\.key)
            // SAFETY: a probe that resolved nothing — or resolved no DIE sensor
            // — is "unresolved", not an answer. Caching [] is non-nil, so the
            // old code never retried, and the very first probe runs right after
            // `start()`'s `port.reset()` closed the connection: one failed lazy
            // reopen blinded the daemon for its whole lifetime.
            //
            // The die requirement is the safety-relevant half. `hottestDieCelsius`
            // is what BOTH the curve and the guardian run on, so a set of only
            // battery and airflow sensors leaves the daemon unable to control or
            // protect anything while looking healthy. Observed for real: one
            // probe resolved 2 sensors on a machine that normally reports 12.
            let hasDie = present.contains(where: SMCKeyMaps.isDieKey)
            guard !present.isEmpty, hasDie else {
                notices.append(
                    "SAFETY: sensor probe unusable (\(present.count) found, die: \(hasDie), "
                        + "model \(model)) — retrying next tick"
                )
                return TemperatureRead(readings: nil, notices: notices)
            }
            sensorKeys = present
            notices.append("resolved \(present.count) temperature sensors (model \(model))")
        }
        var readings: [SensorReading] = []
        var missing: [String] = []
        for key in sensorKeys ?? [] {
            // Only a genuine READ FAILURE counts as missing. A member that
            // reads an implausible value has glitched for this tick, not gone
            // away: it stays in the set and is picked up again when it
            // recovers. Re-probing would not fix a glitch and, before the
            // admission rule above, guaranteed an infinite re-probe loop.
            guard let value = try? await port.readDouble(key) else {
                missing.append(key)
                continue
            }
            // SAFETY: an over-range reading is CLAMPED, never discarded. The
            // plausibility filter caps at 120 °C, so a sensor reporting 121 °C
            // used to vanish from the array entirely — i.e. the single hottest
            // point in the machine silently stopped counting toward the ceiling
            // at exactly the moment it mattered most. Below 10 °C still reads as
            // a dead/unpopulated sensor and is dropped.
            if value >= 120 {
                readings.append(SensorReading(key: key, label: key, celsius: 120))
                continue
            }
            if SMCKeyMaps.isPlausibleTemperature(value) {
                readings.append(SensorReading(key: key, label: key, celsius: value))
            }
            // else: a one-tick glitch on an admitted sensor. Skipped for this
            // evaluation, kept in the set — NOT counted as missing, or a single
            // flapping sensor would re-probe the whole map every couple of ticks.
        }
        guard !readings.isEmpty else {
            // Blindness, NOT an empty set. See the type's doc comment.
            return TemperatureRead(readings: nil, notices: notices)
        }
        // Partial blindness is a health event too. This only reported when
        // EVERY sensor failed, so losing just the hottest one left the ceiling
        // evaluating a set that no longer contained it — with no counter, no
        // log line and no change in HelperStatus. Re-probe once the set
        // shrinks, and say so.
        if missing.count > partialSensorFailureTolerance {
            notices.append(
                "SAFETY: \(missing.count) of \(readings.count + missing.count) sensors unreadable — re-probing"
            )
            sensorKeys = nil
        }
        return TemperatureRead(readings: readings, notices: notices)
    }

    /// How many sensors may drop out before we re-probe the whole set. One
    /// flaky key is normal; a third of them vanishing is a connection problem.
    private var partialSensorFailureTolerance: Int {
        max(1, (sensorKeys?.count ?? 0) / 3)
    }
}
