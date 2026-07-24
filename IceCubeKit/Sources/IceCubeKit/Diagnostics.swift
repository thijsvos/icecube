// Diagnostics.swift — the exportable machine report: host info + fans + sensors + full SMC key dump.

import Foundation

/// One SMC key as captured for the sensors browser and diagnostics export.
public struct SMCKeyDump: Sendable, Codable, Equatable, Identifiable {
    /// The 4-character key name, e.g. `"Tp01"`.
    public let key: String
    /// The 4-character type code as the firmware reports it, e.g. `"flt "`.
    public let type: String
    /// Value size in bytes.
    public let size: Int
    /// Numeric value, when the type has a numeric decoding.
    public let value: Double?
    /// Text value for `flag`/`{fds` keys, when decodable.
    public let text: String?
    /// The raw bytes as uppercase hex — always present, so a report is useful
    /// even for types Ice Cube cannot decode yet.
    public let bytesHex: String

    public var id: String {
        key
    }

    public init(key: String, type: String, size: Int, value: Double?, text: String?, bytesHex: String) {
        self.key = key
        self.type = type
        self.size = size
        self.value = value
        self.text = text
        self.bytesHex = bytesHex
    }
}

/// Host facts for diagnostics, read via `sysctl`/`ProcessInfo`.
public enum HostInfo {
    /// The Mac model identifier (`hw.model`), e.g. `"Mac14,9"`.
    public static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        let bytes = chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? "unknown" : String(decoding: bytes, as: UTF8.self)
    }

    /// The OS version as `"26.4.1"`.
    public static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// The full diagnostics report — what the "new Mac model" GitHub issue
/// template asks users to attach (PLAN.md §3.3): enough to write a curated
/// sensor map for a machine the developers have never touched.
public struct DiagnosticsReport: Sendable, Codable, Equatable {
    /// Bump when the report's shape changes, so tooling can dispatch.
    public let schemaVersion: Int
    public let generatedAt: Date
    public let modelIdentifier: String
    public let osVersion: String
    public let appVersion: String
    /// True when the report describes the simulation, not real hardware —
    /// a simulated report must never be mistaken for a machine mapping.
    public let simulated: Bool
    public let fans: [Fan]
    public let temperatures: [SensorReading]
    public let keys: [SMCKeyDump]

    /// Captures a report from `provider` right now.
    public static func generate(
        provider: any SMCProviding,
        isSimulated: Bool,
        appVersion: String
    ) async throws(IceCubeError) -> DiagnosticsReport {
        let snapshot = try await provider.snapshot()
        return try await DiagnosticsReport(
            schemaVersion: 1,
            generatedAt: snapshot.date,
            modelIdentifier: HostInfo.modelIdentifier(),
            osVersion: HostInfo.osVersion(),
            appVersion: appVersion,
            simulated: isSimulated,
            fans: snapshot.fans,
            temperatures: snapshot.temperatures,
            keys: provider.keyDump()
        )
    }

    /// Stable JSON for export: pretty-printed, sorted keys, ISO-8601 dates —
    /// so two reports from the same machine diff cleanly.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
