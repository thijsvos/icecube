// main.swift — icecube-diag: prints this Mac's SMC diagnostics (summary or full JSON report).

import Foundation
import IceCubeKit

// Usage:
//   swift run icecube-diag              human-readable summary (real hardware)
//   swift run icecube-diag --json       full DiagnosticsReport as JSON
//   swift run icecube-diag --simulated  run against the simulation instead
//   swift run icecube-diag --watch [secs] CSV of fan/temp every 200 ms
let arguments = CommandLine.arguments
let wantsJSON = arguments.contains("--json")
let wantsWatch = arguments.contains("--watch")
let simulated = arguments.contains("--simulated") || ProcessInfo.processInfo.environment["ICECUBE_SIMULATED"] == "1"

let provider: any SMCProviding
do {
    provider = simulated ? MockSMCProvider() : try SystemSMCProvider()
} catch {
    FileHandle.standardError.write(Data("error: cannot open the SMC — \(error.localizedDescription)\n".utf8))
    exit(1)
}

/// Streams fan and die readings as CSV until the duration elapses.
///
/// Exists because sampling by re-running this tool per reading costs a process
/// launch and an SMC open each time — about 2–3 s of resolution, which is far
/// too coarse to see what a fan actually does when it starts from rest. One
/// process, one connection, 5 samples a second shows the real curve.
/// `watts` is logged beside `die_c` because the two together separate "this Mac
/// is working hard" from "this Mac is not being cooled" — a distinction neither
/// temperature nor RPM can make alone, and the first thing worth knowing when
/// someone reports a hot machine.
///
/// It is also how the power-leads-temperature question was settled on real
/// hardware: sample both against one clock across a workload and compare the
/// rises. (It does not lead, usefully — see docs/SMC-KEYS.md.)
func watch(_ provider: any SMCProviding, seconds: Double) async {
    let started = ContinuousClock.now
    print("elapsed_s,fan0_rpm,fan0_target,fan0_mode,fan1_rpm,die_c,watts")
    while (ContinuousClock.now - started) < .seconds(seconds) {
        if let snapshot = try? await provider.snapshot() {
            let elapsed = Double((ContinuousClock.now - started).components.seconds)
                + Double((ContinuousClock.now - started).components.attoseconds) / 1e18
            let fan0 = snapshot.fans.first
            let fan1 = snapshot.fans.dropFirst().first
            let die = snapshot.temperatures.filter(\.isDieSensor).map(\.celsius).max() ?? 0
            // -1 for "this Mac exposes no power key", so a column is always
            // present and a missing signal is visible rather than blank.
            let watts = await (try? provider.power()) ?? nil
            print(String(
                format: "%.2f,%.0f,%.0f,%@,%.0f,%.1f,%.2f",
                elapsed, fan0?.actualRPM ?? -1, fan0?.targetRPM ?? -1,
                "\(fan0.map { "\($0.mode)" } ?? "?")", fan1?.actualRPM ?? -1, die,
                watts ?? -1
            ))
            fflush(stdout)
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
}

if wantsWatch {
    let seconds = arguments.compactMap(Double.init).first ?? 60
    await watch(provider, seconds: seconds)
    exit(0)
}

do {
    let report = try await DiagnosticsReport.generate(
        provider: provider,
        isSimulated: simulated,
        appVersion: "icecube-diag"
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
        // Two numbers, not one. A curated key that is silent right now is
        // almost always a power-gated CPU/GPU cluster rather than a sensor this
        // Mac lacks, and telling those apart is the most useful thing a model
        // report can say. "discovered" is the number that must not move between
        // runs; "reporting" legitimately does.
        let inventory = try await provider.sensorInventory()
        let reporting = Set(report.temperatures.map(\.key))
        print("Sensors:    \(report.temperatures.count) reporting of \(inventory.count) discovered")
        for reading in report.temperatures.sorted(by: { $0.celsius > $1.celsius }) {
            print("  \(reading.key)  \(String(format: "%5.1f", reading.celsius)) °C  \(reading.label)")
        }
        for sensor in inventory where !reporting.contains(sensor.key) {
            print("  \(sensor.key)      —  °C  \(sensor.label) (silent — cluster idle?)")
        }
        print("\nFull report: swift run icecube-diag --json > diagnostics.json")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
