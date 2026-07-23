// main.swift — zephyr-diag: prints this Mac's SMC diagnostics (summary or full JSON report).

import Foundation
import ZephyrKit

// Usage:
//   swift run zephyr-diag              human-readable summary (real hardware)
//   swift run zephyr-diag --json       full DiagnosticsReport as JSON
//   swift run zephyr-diag --simulated  run against the simulation instead
let arguments = CommandLine.arguments
let wantsJSON = arguments.contains("--json")
let simulated = arguments.contains("--simulated") || ProcessInfo.processInfo.environment["ZEPHYR_SIMULATED"] == "1"

let provider: any SMCProviding
do {
    provider = simulated ? MockSMCProvider() : try SystemSMCProvider()
} catch {
    FileHandle.standardError.write(Data("error: cannot open the SMC — \(error.localizedDescription)\n".utf8))
    exit(1)
}

do {
    let report = try await DiagnosticsReport.generate(
        provider: provider,
        isSimulated: simulated,
        appVersion: "zephyr-diag"
    )
    if wantsJSON {
        try print(String(decoding: report.jsonData(), as: UTF8.self))
    } else {
        print("Model:      \(report.modelIdentifier)\(report.simulated ? "  [SIMULATED]" : "")")
        print("macOS:      \(report.osVersion)")
        print("SMC keys:   \(report.keys.count)")
        print("Fans:       \(report.fans.count)")
        for fan in report.fans {
            let rpm = "\(Int(fan.actualRPM)) RPM (target \(Int(fan.targetRPM)), range \(Int(fan.minRPM))–\(Int(fan.maxRPM)))"
            print("  [\(fan.id)] \(fan.name): \(rpm), mode \(fan.mode)")
        }
        print("Sensors:    \(report.temperatures.count)")
        for reading in report.temperatures.sorted(by: { $0.celsius > $1.celsius }) {
            print("  \(reading.key)  \(String(format: "%5.1f", reading.celsius)) °C  \(reading.label)")
        }
        print("\nFull report: swift run zephyr-diag --json > diagnostics.json")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
