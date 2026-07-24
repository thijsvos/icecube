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
///   with the keys that exist on this machine; if that yields fewer than 3
///   sensors the provider falls back to enumerating every `T***` key of type
///   `flt` whose value passes the plausibility filter, labeled by key.
public actor SystemSMCProvider: SMCProviding {
    private let connection: SMCConnection

    /// Resolved once on first use.
    private var discoveredFans: [FanDescriptor]?
    private var discoveredSensors: [SMCKeyMaps.SensorDescriptor]?
    /// Last plausible value per sensor key — what a glitched read falls back
    /// to so the sensor list never shrinks (see `SensorStabilizer`).
    private var lastGoodTemperatures: [String: Double] = [:]
    /// All SMC key names, enumerated once (immutable for a boot).
    private var cachedKeyNames: [String]?

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

    public func temperatures() async throws(IceCubeError) -> [SensorReading] {
        // The list is STATIC after discovery: every discovered sensor appears
        // every tick, in the same order. A read that fails or comes back
        // implausible holds the sensor's last good value instead of dropping
        // the row — vanishing rows made the popover resize every second.
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
        let count = try await Int(connection.readDouble("FNum"))
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
        var resolved: [SMCKeyMaps.SensorDescriptor] = []
        if let curated = SMCKeyMaps.curatedSensors(forModel: HostInfo.modelIdentifier()) {
            // Admission requires a plausible first READ, not mere existence:
            // a key that exists but reads 0 (dead/unpopulated sensor) would
            // otherwise become a permanent junk row. The read also seeds the
            // hold-last-good cache, so membership never changes afterwards.
            for sensor in curated {
                guard let value = try? await connection.readDouble(sensor.key),
                      SMCKeyMaps.isPlausibleTemperature(value) else { continue }
                lastGoodTemperatures[sensor.key] = value
                resolved.append(sensor)
            }
        }
        if resolved.count < 3 {
            resolved = try await enumeratedTemperatureSensors()
        }
        discoveredSensors = resolved
        return resolved
    }

    /// The unknown-model fallback: every `T***` key of type `flt` whose
    /// current value is plausible, labeled by its key. Ugly labels, real data
    /// — and the sensors browser + diagnostics report exist so the community
    /// can turn exactly this situation into a curated mapping.
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
