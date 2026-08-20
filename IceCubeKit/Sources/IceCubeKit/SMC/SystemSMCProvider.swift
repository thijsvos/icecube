// SystemSMCProvider.swift — real read-only SMC access: fan discovery, curated/fallback sensors, key dump.

import Foundation

/// The real-hardware implementation of ``SMCProviding``: unprivileged,
/// read-only IOKit calls through one ``SMCConnection``.
///
/// Discovery happens once, lazily, then is cached for the process lifetime:
/// - **Fans**: `FNum` gives the count; per fan we read `F{i}Ac`/`F{i}Tg`/
///   `F{i}Mn`/`F{i}Mx` every poll, plus (once) the name from `F{i}ID` and the
///   mode-key casing (`F{i}Md` vs `F{i}md` — it varies by SoC generation).
///   `FNum == 0` is a fanless Mac (MacBook Air): monitoring still works.
/// - **Sensors**: the curated per-generation map (``SMCKeyMaps``) intersected
///   with the keys this machine actually has — an **existence** test, never a
///   value test (see ``SensorAdmission``); if that yields fewer than 3 sensors
///   the provider falls back to enumerating every `T***` key of type `flt`
///   whose value passes the plausibility filter, labeled by key.
public actor SystemSMCProvider: SMCProviding {
    /// The SMC, behind ``SMCReadPort`` rather than as a concrete
    /// `SMCConnection`, so the decisions in this file can be exercised against
    /// a scripted fake instead of a Mac.
    private let connection: any SMCReadPort

    /// This Mac's `hw.model`, injected.
    ///
    /// Not a detail: `performSensorDiscovery` picks the curated map or the
    /// enumeration fallback from this string, so with it read straight from
    /// `sysctl` **the branch a test takes depends on the machine running the
    /// suite**. That is not hypothetical — the first version of these tests
    /// passed on the owner's Mac14,9, where the curated branch wins, and failed
    /// on CI, where a different model falls through to enumeration.
    private let model: @Sendable () -> String

    /// Resolved once on first use.
    private var discoveredFans: [FanDescriptor]?
    private var discoveredSensors: [SMCKeyMaps.SensorDescriptor]?
    /// Sensor discovery currently in flight, so concurrent callers join it
    /// instead of each running the full sweep. See ``sensorDescriptors()``.
    private var sensorDiscovery: Task<[SMCKeyMaps.SensorDescriptor], any Error>?
    /// Last plausible value per sensor key — what a glitched read falls back
    /// to so the sensor list never shrinks (see `SensorStabilizer`).
    ///
    /// Empty until the first poll: discovery now admits sensors without reading
    /// them, so a sensor whose cluster is power-gated at launch is admitted
    /// with no value and publishes no row until it first reports. That is the
    /// published list's one growth phase.
    private var lastGoodTemperatures: [String: Double] = [:]
    /// All SMC key names, enumerated once (immutable for a boot).
    private var cachedKeyNames: [String]?
    /// Which power key this Mac uses, resolved once.
    ///
    /// Double-optional on purpose, matching the discovery caches above: the
    /// outer `nil` means "not resolved yet", the inner means "resolved, and
    /// this machine has none". Without the distinction a Mac with no power key
    /// would re-probe every candidate on every 2 s tick, forever.
    private var resolvedPowerKey: String??

    /// What we remember about one fan after discovery.
    private struct FanDescriptor {
        let id: Int
        let name: String
        /// The full mode-key name for this fan (`"F0Md"` or `"F0md"`), or
        /// `nil` when the machine exposes none — reported as `.system`.
        let modeKey: String?
    }

    /// Opens the SMC. Throws `IceCubeError.smcConnectionFailed` when there is
    /// no AppleSMC service to talk to.
    public init() throws(IceCubeError) {
        connection = try SMCConnection()
        model = HostInfo.modelIdentifier
    }

    /// Builds a provider over an arbitrary read port.
    ///
    /// For tests, and for a future Intel or remote provider. Production keeps
    /// using ``init()``, which owns the real connection — nothing about the
    /// capability boundary changes, because this port cannot write.
    public init(
        connection: any SMCReadPort,
        model: @escaping @Sendable () -> String = HostInfo.modelIdentifier
    ) {
        self.connection = connection
        self.model = model
    }

    // MARK: - SMCProviding

    public func fans() async throws(IceCubeError) -> [Fan] {
        var result: [Fan] = []
        for descriptor in try await fanDescriptors() {
            let i = descriptor.id
            let actual = try await connection.readDouble("F\(i)Ac")
            // Tg/Mn/Mx are occasionally absent on exotic hardware; degrade
            // per-key rather than losing the whole fan.
            let target = await (try? connection.readDouble("F\(i)Tg")) ?? actual
            let minRPM = await (try? connection.readDouble("F\(i)Mn")) ?? 0
            let maxRPM = await (try? connection.readDouble("F\(i)Mx")) ?? 0
            var mode = FanMode.system
            if let modeKey = descriptor.modeKey,
               let raw = try? await connection.readDouble(modeKey)
            {
                mode = FanMode(smcValue: raw)
            }
            result.append(Fan(
                id: i,
                name: descriptor.name,
                mode: mode,
                actualRPM: actual,
                targetRPM: target,
                minRPM: minRPM,
                maxRPM: maxRPM
            ))
        }
        return result
    }

    /// What this Mac **has**, as opposed to what is reporting right now.
    ///
    /// Stable from the first poll, because admission is by key existence. The
    /// difference between the two numbers is the whole subject of
    /// ``SensorAdmission``, and `icecube-diag` prints both so the stability
    /// claim is checkable on hardware rather than asserted in a comment.
    public func sensorInventory() async throws(IceCubeError) -> [SMCKeyMaps.SensorDescriptor] {
        try await sensorDescriptors()
    }

    public func temperatures() async throws(IceCubeError) -> [SensorReading] {
        // Every sensor that has ever reported appears every tick, in the same
        // order. A read that fails or comes back implausible holds the sensor's
        // last good value instead of dropping the row — vanishing rows made the
        // popover resize every second.
        //
        // MONOTONE rather than fixed-at-discovery: membership is decided by key
        // existence, and a power-gated cluster reports only a sentinel for up
        // to ~85 s after launch (measured on Mac14,9), so those rows join late
        // and then never leave. Admitted-but-silent keys are simply re-read
        // every tick — there is nothing to re-probe, which is what makes the
        // daemon's re-probe loop impossible here.
        let sensors = try await sensorDescriptors()
        var fresh: [String: Double] = [:]
        for sensor in sensors {
            if let value = try? await connection.readDouble(sensor.key) {
                fresh[sensor.key] = value
            }
        }
        let (readings, cache) = SensorStabilizer.stabilize(
            sensors: sensors, freshValues: fresh, lastGood: lastGoodTemperatures
        )
        lastGoodTemperatures = cache
        return readings
    }

    public func power() async throws(IceCubeError) -> Double? {
        guard let key = await powerKey() else { return nil }
        guard let watts = try? await connection.readDouble(key),
              SMCKeyMaps.isPlausiblePower(watts)
        else {
            // A single implausible read is NOT cause to forget the key — one
            // glitch would otherwise cost the reading for the rest of the boot.
            // Callers treat nil as "no figure this time" and show nothing,
            // which beats showing a wrong wattage.
            return nil
        }
        return watts
    }

    /// The power key for this Mac, probed once against the candidate list.
    ///
    /// A candidate must both EXIST and read plausibly to be accepted: of the 79
    /// `P***` keys on Mac14,9 only 38 carry a live value, so a presence check
    /// alone would happily latch onto one that reads 0 W forever while looking
    /// like it had worked.
    private func powerKey() async -> String? {
        if let resolvedPowerKey {
            return resolvedPowerKey
        }
        for candidate in SMCKeyMaps.powerKeyCandidates {
            guard await connection.hasKey(candidate),
                  let watts = try? await connection.readDouble(candidate),
                  SMCKeyMaps.isPlausiblePower(watts)
            else { continue }
            resolvedPowerKey = .some(candidate)
            return candidate
        }
        resolvedPowerKey = .some(nil)
        return nil
    }

    public func keyDump() async throws(IceCubeError) -> [SMCKeyDump] {
        // Key NAMES and the #KEY count are immutable for a boot; only values
        // change. Enumerate the names once (skipping unprintable oddities),
        // then every refresh only re-reads values — the Sensors window polls
        // this every 2 s, so this halves the syscall load on the heavy path.
        let keys = try await enumeratedKeyNames()
        var dump: [SMCKeyDump] = []
        dump.reserveCapacity(keys.count)
        for key in keys {
            guard let (bytes, info) = try? await connection.readBytes(key) else { continue }
            var value: Double?
            var text: String?
            if let type = SMCDataType(rawValue: info.type) {
                switch type {
                case .flag:
                    text = (try? SMCKeyCodec.decodeBool(bytes, forKey: key)).map(String.init)
                case .fanDescriptor:
                    text = try? SMCKeyCodec.decodeString(bytes, forKey: key)
                // Exhaustive on purpose: SMCDataType is a growing set, and this
                // key dump is where a new wire type is most likely to show up.
                // A `default:` would route it to decodeDouble, throw, get
                // swallowed by try?, and render as "—" with no clue.
                case .float, .fpe2, .uint8, .uint16, .uint32:
                    value = try? SMCKeyCodec.decodeDouble(bytes, as: type, forKey: key)
                }
            }
            dump.append(SMCKeyDump(
                key: key,
                type: info.type,
                size: info.size,
                value: value,
                text: text,
                bytesHex: bytes.smcHexString
            ))
        }
        return dump
    }

    /// Every SMC key name, enumerated once and cached (names don't change
    /// for a boot). Unprintable/garbage names are skipped.
    private func enumeratedKeyNames() async throws(IceCubeError) -> [String] {
        if let cachedKeyNames {
            return cachedKeyNames
        }
        let count = try await connection.keyCount()
        var names: [String] = []
        names.reserveCapacity(count)
        for index in 0 ..< count {
            if let key = try? await connection.key(atIndex: index) {
                names.append(key)
            }
        }
        cachedKeyNames = names
        return names
    }

    // MARK: - Discovery (cached)

    private func fanDescriptors() async throws(IceCubeError) -> [FanDescriptor] {
        if let discoveredFans {
            return discoveredFans
        }
        // `Int(someDouble)` traps on NaN/±inf and on anything past Int.max, so a
        // garbage `FNum` would take down the app process rather than the fan
        // list. `SensorReader.readFans()` guards the identical read on the
        // daemon side and has since it was written; this copy did not.
        let rawCount = try await connection.readDouble("FNum")
        guard let count = Int(exactly: rawCount.rounded(.towardZero)), (0 ... 64).contains(count) else {
            throw IceCubeError.smcDecodingFailed(key: "FNum", type: "fan count", bytes: [])
        }
        // Mode-key casing is machine-wide; probe once with fan 0.
        let modeSuffix: String? = if count == 0 {
            nil
        } else if await connection.hasKey("F0Md") {
            "Md"
        } else if await connection.hasKey("F0md") {
            "md"
        } else {
            nil
        }
        var descriptors: [FanDescriptor] = []
        for i in 0 ..< count {
            await descriptors.append(FanDescriptor(
                id: i,
                name: fanName(index: i, totalFans: count),
                modeKey: modeSuffix.map { "F\(i)\($0)" }
            ))
        }
        discoveredFans = descriptors
        return descriptors
    }

    /// Best available name for fan `index`: the `F{i}ID` descriptor when the
    /// machine has one, else the MacBook Pro convention (fan 0 left, fan 1
    /// right), else a number.
    private func fanName(index: Int, totalFans: Int) async -> String {
        if let name = try? await connection.readString("F\(index)ID"), !name.isEmpty {
            return name
        }
        if totalFans == 2 {
            return index == 0 ? "Left" : "Right"
        }
        return "Fan \(index + 1)"
    }

    private func sensorDescriptors() async throws(IceCubeError) -> [SMCKeyMaps.SensorDescriptor] {
        if let discoveredSensors {
            return discoveredSensors
        }
        // ACTOR REENTRANCY: every line below suspends, and the cache is only
        // assigned at the end — so two callers arriving before the first
        // finishes both saw nil and both ran the whole sweep (which, on an
        // unmapped model, enumerates EVERY SMC key). Awaiting an in-flight
        // discovery makes the second caller join rather than duplicate it.
        if let sensorDiscovery {
            return try await Self.value(of: sensorDiscovery)
        }
        let discovery = Task<[SMCKeyMaps.SensorDescriptor], any Error> {
            try await self.performSensorDiscovery()
        }
        sensorDiscovery = discovery
        defer { sensorDiscovery = nil }
        let resolved = try await Self.value(of: discovery)
        discoveredSensors = resolved
        return resolved
    }

    /// Re-narrows a `Task`'s `any Error` back to `IceCubeError`.
    ///
    /// `Task` has no typed-throws initializer, so an in-flight discovery has to
    /// be stored as `Task<_, any Error>` even though the work only ever throws
    /// `IceCubeError`. This keeps the callers' typed-throws signatures intact.
    private static func value<T>(of task: Task<T, any Error>) async throws(IceCubeError) -> T {
        do {
            return try await task.value
        } catch let error as IceCubeError {
            throw error
        } catch {
            throw IceCubeError.smcKeyNotFound(key: "T***")
        }
    }

    private func performSensorDiscovery() async throws(IceCubeError) -> [SMCKeyMaps.SensorDescriptor] {
        var resolved: [SMCKeyMaps.SensorDescriptor] = []
        if let curated = SMCKeyMaps.curatedSensors(forModel: model()) {
            // Membership comes from key EXISTENCE, never from a first reading.
            // Admitting on a plausible read made the sensor list a per-launch
            // lottery — five consecutive `icecube-diag` runs on an idle Mac14,9
            // resolved 20, 16, 20, 16, 20 of the same 20 keys — because a
            // power-gated CPU cluster reports a frozen 6.70/4.63 °C sentinel
            // that the plausibility floor rejects. `SensorAdmission` carries
            // the measurements, and the remedies they ruled out.
            //
            // One `keyInfo` call answers both questions, and `SMCConnection`
            // caches it for the rest of the process — less SMC traffic than the
            // value probe it replaces, and it still runs exactly once.
            var probes: [String: SensorAdmission.Probe] = [:]
            probes.reserveCapacity(curated.count)
            for sensor in curated {
                do {
                    let info = try await connection.keyInfo(for: sensor.key)
                    probes[sensor.key] = .present(type: info.type)
                } catch {
                    // "No such key" is an ANSWER, and a stable one — it is a
                    // property of the model. Anything else (transport failure,
                    // a connection that went away on wake) is not an answer, so
                    // it propagates: `sensorDescriptors()` must never cache a
                    // truncated list for the life of the process, and the next
                    // poll retries. This is the daemon's "an EMPTY probe is
                    // unresolved, not 'this Mac has no sensors'" lesson.
                    guard case .smcKeyNotFound = error else { throw error }
                    probes[sensor.key] = .absent
                }
            }
            resolved = SensorAdmission.admit(candidates: curated, probes: probes)
        }
        // Fewer than three curated keys means the map does not describe this
        // machine — not that the moment was unlucky. Under existence-based
        // admission this no longer fires on a badly-timed probe, which is what
        // used to drop a perfectly mapped Mac to raw-key labels.
        if resolved.count < 3 {
            resolved = try await enumeratedTemperatureSensors()
        }
        return resolved
    }

    /// The unknown-model fallback: every `T***` key of type `flt` whose current
    /// value is plausible, labeled by its key.
    ///
    /// Ugly labels, real data — and the sensors browser + diagnostics report
    /// exist so the community can turn exactly this situation into a curated
    /// mapping.
    private func enumeratedTemperatureSensors() async throws(IceCubeError) -> [SMCKeyMaps.SensorDescriptor] {
        let count = try await connection.keyCount()
        var found: [SMCKeyMaps.SensorDescriptor] = []
        for index in 0 ..< count {
            guard let key = try? await connection.key(atIndex: index), key.hasPrefix("T"),
                  let info = try? await connection.keyInfo(for: key),
                  info.type == SMCDataType.float.rawValue,
                  let value = try? await connection.readDouble(key),
                  SMCKeyMaps.isPlausibleTemperature(value) else { continue }
            lastGoodTemperatures[key] = value // seed the hold-last-good cache
            found.append(SMCKeyMaps.SensorDescriptor(key: key, label: key))
        }
        return found
    }
}
