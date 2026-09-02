// main.swift — icecube-diag: prints this Mac's SMC diagnostics (summary or full JSON report).

import Foundation
import IceCubeKit

// Usage:
//   swift run icecube-diag              human-readable summary (real hardware)
//   swift run icecube-diag --json       full DiagnosticsReport as JSON
//   swift run icecube-diag --simulated  run against the simulation instead
//   swift run icecube-diag --watch [secs] CSV of fan/temp every 200 ms
//   swift run icecube-diag --processes  per-process watts vs system total
//   swift run icecube-diag --forecast [secs]  measure this Mac's thermal time constant
let arguments = CommandLine.arguments
let wantsJSON = arguments.contains("--json")
let wantsWatch = arguments.contains("--watch")
let wantsProcesses = arguments.contains("--processes")
let wantsForecast = arguments.contains("--forecast")
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

/// Prints per-process watts beside the SMC's system total.
///
/// **Opt-in, and deliberately absent from both the default summary and
/// `--json`.** Those two are what people paste into public issues, and process
/// names say what someone works on. This flag exists for the person holding the
/// machine, and for ground-truthing ``SystemProcessSampler`` against
/// `powermetrics`.
///
/// Two samples, because `ri_energy_nj` is a counter: the first establishes a
/// baseline and only the second can be divided into watts.
func showProcesses(_ provider: any SMCProviding, sampler: any ProcessSampling) async {
    _ = await sampler.sample()
    try? await Task.sleep(for: .seconds(2))
    guard let reading = await sampler.sample() else {
        print("No reading — too little time elapsed between samples.")
        return
    }

    let systemWatts = await (try? provider.power()) ?? nil
    print("Interval:   \(String(format: "%.2f", reading.interval)) s")
    if let systemWatts {
        print("System:     \(String(format: "%.1f", systemWatts)) W  (PSTR — the whole machine)")
    } else {
        print("System:     — (this Mac exposes no usable power key)")
    }
    let readable = reading.totalCount - reading.unreadableCount
    print(
        "Attributed: \(String(format: "%.1f", reading.attributedWatts)) W"
            + "  (CPU energy of all \(readable) readable processes)"
    )
    if let systemWatts {
        let remainder = systemWatts - reading.attributedWatts
        print(
            "Remainder:  \(String(format: "%.1f", remainder)) W"
                + "  (display, SSD, radios, GPU, and \(reading.unreadableCount) processes needing root)"
        )
    }
    print("Processes:  \(readable) readable of \(reading.totalCount)"
        + "  (\(reading.unreadableCount) need root — kernel_task, WindowServer, other users)")
    print("\nTop \(reading.processes.count) by draw:")
    for sample in reading.processes {
        print(String(format: "  %6.2f W  %@ (%d)", sample.watts, sample.name, sample.pid))
    }
    print("\nThese do not sum to the system total, and should not — see docs/DIAGNOSIS.md.")
}

/// Samples the SMC for `seconds`, feeding every tick to ``ThermalTimeConstant``,
/// and prints the distribution of τ it accepted plus why it refused the rest.
///
/// **This is an instrument, not a feature.** It is what measured τ on the
/// reference Mac14,9 on 2026-09-01: 1800 s of ordinary use, 89 accepted
/// estimates, median **73.7 s** — inside the 45–135 s that `R ≈ 0.9 °C/W` and a
/// 50–150 J/°C heatsink predicted. ``ThermalTimeConstant/minimumPlausible``
/// carries the distribution and the reason the bounds did not move. Re-run it
/// on new hardware; the forecast row that ships on top of it is behind
/// Settings → General → Experimental.
///
/// The refusal tally matters as much as the median. A gate that rejects
/// everything is indistinguishable, from the outside, from a machine that
/// never ramps — and the two call for opposite fixes.
func forecast(_ provider: any SMCProviding, seconds: Double) async {
    var subject = ThermalTimeConstant()
    var refusals: [String: Int] = [:]
    var ticks = 0
    let started = ContinuousClock.now

    print("Sampling for \(Int(seconds)) s. Give the Mac something to do — a build, a render —")
    print("then let it go quiet again. Transients are the only place a time constant lives.\n")

    while (ContinuousClock.now - started) < .seconds(seconds) {
        if let snapshot = try? await provider.snapshot(),
           let watts = snapshot.power,
           let ambient = CoolingEfficiency.ambient(from: snapshot.temperatures),
           let die = snapshot.temperatures.filter(\.sensorClass.isDie).map(\.celsius).max()
        {
            let usable = snapshot.fans.filter(\.hasUsableRange)
            let fraction = usable.isEmpty
                ? 0
                : usable.map { $0.actualRPM / $0.maxRPM }.reduce(0, +) / Double(usable.count)
            subject.ingest(ThermalTimeConstant.Observation(
                date: snapshot.date,
                dieCelsius: die,
                ambientCelsius: ambient,
                watts: watts,
                fanFraction: fraction
            ))
            ticks += 1
            let name = subject.lastRefusal.map { "\($0)".prefix(while: { $0 != "(" }) } ?? "accepted"
            refusals[String(name), default: 0] += 1
            if ticks % 30 == 0 {
                let tau = subject.tau.map { String(format: "%.0f s", $0) } ?? "—"
                print("  \(ticks) ticks · \(subject.estimateCount) estimates · τ \(tau)")
            }
        }
        try? await Task.sleep(for: .seconds(1))
    }

    print("\nTime constant")
    if subject.estimateCount == 0 {
        print("  no estimates — the machine never ramped with everything else held still")
    } else {
        for p in [10.0, 25.0, 50.0, 75.0, 90.0] {
            let value = subject.percentile(p).map { String(format: "%6.1f s", $0) } ?? "     —"
            print("  p\(Int(p))\(p < 100 ? " " : "")  \(value)")
        }
        print("  estimates: \(subject.estimateCount) of \(ticks) ticks")
        let reported = subject.tau.map { String(format: "%.0f s", $0) } ?? "— (below the evidence bar)"
        print("  reported:  \(reported)")
        print(
            "  band:      \(Int(ThermalTimeConstant.minimumPlausible))–\(Int(ThermalTimeConstant.maximumPlausible)) s (plausibility bounds, kept after the 2026-09-01 run)"
        )
    }

    print("\nWhy the rest were refused")
    for (reason, count) in refusals.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %-26@ %4d", reason as NSString, count))
    }

    print("\nCooling law (from the recorded history)")
    switch loadedHistory() {
    case let .success(history):
        let law = CoolingLaw.fit(history)
        if law.measuredBands.isEmpty {
            print("  no band has enough records with a wide enough spread of draw yet")
            print("  (\(history.records.count) raw records, needs \(CoolingLaw.minimumRecordsPerBand) per band")
            print("   spanning \(Int(CoolingLaw.minimumPowerSpreadFraction * 100)) % of their mean)")
        } else {
            for band in law.measuredBands {
                guard let fit = law.band(band) else { continue }
                print(String(
                    format: "  band %-2d  ΔT = %.3f·W %@ %.1f   n=%d  %.1f–%.1f W  residual %.2f °C",
                    band.sortKey, fit.slope, (fit.intercept < 0 ? "−" : "+") as NSString,
                    abs(fit.intercept), fit.records,
                    fit.wattsRange.lowerBound, fit.wattsRange.upperBound, fit.residual
                ))
            }
        }
    case let .failure(why):
        print("  \(why.message)")
    }
}

/// Reads the app's cooling history from disk, read-only.
///
/// `CoolingHistoryStore` lives in the app target, so this reaches the file
/// directly rather than importing UI code into a CLI. It only ever reads —
/// a diagnostic tool that could rewrite the history it is reporting on would
/// be a bad trade for a few lines saved.
func loadedHistory() -> Result<CoolingHistory, HistoryUnavailable> {
    let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/IceCube/cooling-history.json")
    guard let data = try? Data(contentsOf: path) else {
        return .failure(HistoryUnavailable("no history file yet — run the app for a while first"))
    }
    switch CoolingHistory.decode(
        data,
        modelIdentifier: HostInfo.modelIdentifier(),
        isSimulated: simulated,
        serialNumber: HostInfo.serialNumber()
    ) {
    case let .loaded(history):
        return .success(history)
    case let .readOnly(reason):
        // A file newer than this build understands carries no decoded history
        // to report on, and must not be rewritten to make one.
        return .failure(HistoryUnavailable("history is newer than this build (\(reason))"))
    case let .startFresh(reason):
        return .failure(HistoryUnavailable("history unusable: \(reason)"))
    }
}

/// Why there is no history to fit. A named type only because `Result` needs
/// its failure to be an `Error`; the message is the whole of it.
struct HistoryUnavailable: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

if wantsForecast {
    let seconds = arguments.compactMap(Double.init).first ?? 600
    await forecast(provider, seconds: seconds)
    exit(0)
}

if wantsProcesses {
    let sampler: any ProcessSampling = simulated ? MockProcessSampler() : SystemProcessSampler()
    await showProcesses(provider, sampler: sampler)
    exit(0)
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
        // Watts beside the temperatures, which is the pairing this tool's own
        // header has argued for since it was written: it is what separates
        // "you are running something heavy" from "your cooling is not working".
        // R needs a settled window, which a one-shot run does not have — say so
        // rather than printing a transient quotient.
        if let watts = report.watts {
            print("Power:      \(String(format: "%.1f", watts)) W  (PSTR — system total)")
            let die = report.temperatures.filter { SMCKeyMaps.isDieKey($0.key) }.map(\.celsius).max()
            let ambient = CoolingEfficiency.ambient(from: report.temperatures)
            if let die, let ambient,
               let r = CoolingEfficiency.resistance(dieCelsius: die, ambientCelsius: ambient, watts: watts)
            {
                print(
                    "Cooling:    \(String(format: "%.2f", r)) °C/W  (instantaneous — a settled figure needs the app, which holds the 20 s window)"
                )
            }
        } else {
            print("Power:      — (this Mac exposes no usable power key)")
        }
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
