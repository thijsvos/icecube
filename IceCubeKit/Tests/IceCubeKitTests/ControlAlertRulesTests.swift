// ControlAlertRulesTests.swift — the only thing that matters here is how often it stays quiet.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("Control alerts")
struct ControlAlertRulesTests {
    typealias Alert = ControlAlertRules.Alert
    typealias State = ControlAlertRules.State

    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ minutes: Double) -> Date {
        epoch.addingTimeInterval(minutes * 60)
    }

    /// Built through the classifying initialiser on purpose. These tests feed
    /// the daemon's **real sentences** and let `Kind.classify` sort them, so the
    /// suite also pins that the wording the daemon actually emits still lands in
    /// the class this feature keys on.
    static func decision(_ text: String, at date: Date) -> DecisionEvent {
        DecisionEvent(text: text, date: date)
    }

    static func fan(id: Int = 0, actual: Double, max: Double = 6800) -> Fan {
        Fan(id: id, name: "Left", mode: .forced, actualRPM: actual, targetRPM: max, minRPM: 2317, maxRPM: max)
    }

    @discardableResult
    static func run(
        _ state: inout State,
        decisions: [DecisionEvent] = [],
        fans: [Fan] = [fan(actual: 3000)],
        at date: Date,
        enabled: Set<Alert.Category> = Set(Alert.Category.allCases)
    ) -> [Alert] {
        ControlAlertRules.evaluate(
            freshDecisions: decisions, fans: fans, now: date, state: &state, enabled: enabled
        )
    }

    // MARK: - It speaks at all

    @Test("A safety decision is worth interrupting someone for")
    func safetySpeaks() {
        var state = State()
        // A genuine fault. The first version of this test used "system did not
        // resume control", which is the guardian working — so the test asserted
        // the very behaviour that turned out to be noise on real hardware.
        let event = Self.decision(
            "SAFETY: control lost (read-back failed twice) — reverting to auto",
            at: Self.at(0)
        )
        let alerts = Self.run(&state, decisions: [event], at: Self.at(0))

        #expect(alerts.count == 1)
        #expect(alerts.first?.category == .lostControl)
        #expect(alerts.first?.title == "Ice Cube lost fan control")
        // The daemon's own sentence, not a paraphrase.
        #expect(alerts.first?.body == event.text)
    }

    @Test("A guardian engagement is reported as Ice Cube working, not as an alarm")
    func guardianSpeaks() {
        var state = State()
        let event = Self.decision(
            "guardian: die 76 °C and nothing cooling — driving the fans (built-in curve)",
            at: Self.at(0)
        )
        let alerts = Self.run(&state, decisions: [event], at: Self.at(0))

        #expect(alerts.first?.category == .guardianEngaged)
        #expect(alerts.first?.title == "Ice Cube is cooling your Mac")
    }

    /// Routine daemon chatter must never reach a banner. `engaged`/`released`
    /// happen on every preset change and every quit.
    @Test(
        "Routine decisions never interrupt",
        arguments: [
            "curve engaged (persists without app: false)",
            "all fans auto (daemon shutdown)",
            "write-path self-test: verified",
            "wake: resuming — the system powered on",
        ]
    )
    func routineDecisionsAreSilent(text: String) {
        var state = State()
        #expect(Self.run(&state, decisions: [Self.decision(text, at: Self.at(0))], at: Self.at(0)).isEmpty)
    }

    // MARK: - Routine safety lines must not interrupt

    /// The regression test for this feature's first real firing.
    ///
    /// Five seconds after a v0.3.0 install it said "Ice Cube lost fan control",
    /// about `holdAtFloor` — the guardian holding the fans because macOS had not
    /// taken them back. That is Ice Cube working, it follows every revert on
    /// this hardware, and it is not something a person can act on.
    @Test("The line that fires after every daemon restart is not an alert")
    func guardianFloorHoldIsRoutine() {
        var state = State()
        let event = Self.decision(
            "SAFETY: system did not resume control — holding fans at minimum RPM ourselves",
            at: Self.at(0)
        )
        #expect(event.kind == .safety, "still a safety line — it belongs in the log and on the chart")
        #expect(Self.run(&state, decisions: [event], at: Self.at(0)).isEmpty, "…but not in a banner")
    }

    /// Replays the exact restart sequence from the owner's log, 2026-08-07.
    /// An update must be silent.
    @Test("Installing an update produces no notification")
    func anUpdateIsSilent() {
        var state = State()
        let script = [
            "all fans auto (app connection invalidated)",
            "SAFETY: system did not resume control — holding fans at minimum RPM ourselves",
            "all fans auto (daemon shutdown)",
            "all fans auto (daemon start)",
            "SAFETY: system did not resume control — holding fans at minimum RPM ourselves",
            "curve engaged (persists without app: false)",
        ]
        var alerts: [Alert] = []
        for (index, text) in script.enumerated() {
            alerts += Self.run(
                &state,
                decisions: [Self.decision(text, at: Self.at(Double(index)))],
                at: Self.at(Double(index))
            )
        }
        #expect(alerts.isEmpty, "a routine update must not interrupt: got \(alerts.map(\.title))")
    }

    @Test("Genuine faults still interrupt", arguments: [
        "SAFETY: control lost (read-back failed twice) — reverting to auto",
        "SAFETY: fan write failed mid-sequence — reverting (0x84)",
        "SAFETY: forcing maximum cooling — Tp01 at 110 °C",
        "SAFETY: wake re-assert failed — reverting to auto",
        "SAFETY: sensor probe unusable (0 found, die: false, model Mac16,1) — retrying next tick",
    ])
    func realFaultsStillSpeak(text: String) {
        var state = State()
        #expect(Self.run(&state, decisions: [Self.decision(text, at: Self.at(0))], at: Self.at(0)).count == 1)
    }

    /// The daemon's complete safety vocabulary, and what each one is worth.
    ///
    /// Hand-written, and that is the point. `routineSafetyMarkers` matches on
    /// substrings, which normally rots the moment somebody rewords a sentence —
    /// so the table below states the intended answer **independently**, and the
    /// test beneath it compares the source, the table and the implementation
    /// three ways. A first attempt at this guard asserted the implementation
    /// against a value derived from the implementation, which is a tautology and
    /// survived a mutation that reworded a daemon sentence.
    ///
    /// `true` = worth interrupting someone. `false` = Ice Cube working.
    static let safetyVocabulary: [String: Bool] = [
        "SAFETY: awake ": false,
        "SAFETY: control lost (read-back failed twice) — reverting to auto": true,
        "SAFETY: could not re-park orphaned fan(s): ": true,
        "SAFETY: could not read the fans to park them for sleep — they may still be forced": true,
        "SAFETY: curve control lost (read-back failed twice) — reverting to auto": true,
        "SAFETY: fan write failed mid-sequence — reverting (": true,
        "SAFETY: fan write raced a revert — reverting again": false,
        // Past tense, and only recorded once the writes landed. The re-park
        // SUCCEEDING is Ice Cube working; the failure above is not, which is why
        // they are two sentences and not one with a suffix.
        "SAFETY: fan(s) orphaned in mode 0 — re-parked, handed back, resetting SMC connection": false,
        "SAFETY: forcing maximum cooling — ": true,
        // The guardian failing to hand the fans back is the headline failure this
        // whole class of bug produces: fans physically forced while every safety
        // net believes the firmware owns them. Always worth interrupting someone.
        "SAFETY: guardian could not release the fans ": true,
        "SAFETY: over the temperature ceiling while parked for sleep (": true,
        "SAFETY: parking for sleep while the temperature ceiling is active — the firmware owns cooling now": false,
        "SAFETY: parking the fans for sleep failed (": true,
        "SAFETY: revert could not be applied (": true,
        "SAFETY: reverting to auto — ": true,
        "SAFETY: sensor probe unusable (": true,
        "SAFETY: system did not resume control — holding fans at minimum RPM ourselves": false,
        "SAFETY: wake re-assert failed — reverting to auto": true,
    ]

    /// Reads the daemon's **actual source** and requires its safety vocabulary
    /// to match the table above exactly.
    ///
    /// This is what makes substring matching safe: a new or reworded `SAFETY:`
    /// line fails here, and whoever wrote it has to decide, in the table,
    /// whether it should interrupt somebody. Without it an unlisted sentence
    /// silently defaults to "interrupt", which is how a notifier gets muted.
    @Test("The daemon's safety vocabulary has not changed behind this feature's back")
    func safetyVocabularyIsPinned() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/IceCubeKit/Helper")

        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "could not find the daemon sources at \(sources.path)")

        var inSource: Set<String> = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                guard line.contains("\"SAFETY: "), !line.trimmingCharacters(in: .whitespaces).hasPrefix("///")
                else { continue }
                guard let start = line.range(of: "\"SAFETY: ") else { continue }
                let literal = String(line[start.lowerBound...].dropFirst().prefix { $0 != "\"" && $0 != "\\" })
                if literal != "SAFETY: " {
                    inSource.insert(literal)
                }
            }
        }

        let expected = Set(Self.safetyVocabulary.keys)
        let added = inSource.subtracting(expected)
        let removed = expected.subtracting(inSource)
        #expect(
            inSource == expected,
            "the daemon's safety vocabulary changed — added \(added), removed \(removed). Update "
        )
    }

    /// And the implementation must agree with the table.
    @Test("Each safety sentence is classified the way the table says")
    func classificationMatchesTheTable() {
        for (sentence, shouldNotify) in Self.safetyVocabulary {
            let event = DecisionEvent(text: sentence + "x", date: Date())
            #expect(
                ControlAlertRules.isNotifiable(event) == shouldNotify,
                "\(sentence) — expected notifiable=\(shouldNotify)"
            )
        }
    }

    // MARK: - The part that decides whether this feature survives contact with a user

    /// The storm this feature could cause during the failure it exists to
    /// report. `DaemonCore` documents a stuck SMC writing a revert-failure line
    /// **every 2 s** — 300 of them in ten minutes.
    @Test("A failure repeating every 2 s for ten minutes produces one notification")
    func stormProducesOneAlert() {
        var state = State()
        var spoken = 0
        for tick in 0 ..< 300 {
            let now = Self.epoch.addingTimeInterval(Double(tick) * 2)
            let event = Self.decision("SAFETY: fan write failed mid-sequence", at: now)
            spoken += Self.run(&state, decisions: [event], at: now).count
        }
        #expect(spoken == 1, "300 identical failures in ten minutes must not be 300 banners")
    }

    /// **The real week.** These are the owner's actual events from the unified
    /// log, 2026-08-07, over seven days: 5 safety, 10 guardian, 6 routine
    /// reverts. Fifteen of them are currently silent.
    ///
    /// The test asserts the feature lands between its two failure modes — one
    /// banner per event is a mute-me machine, and one banner per week is a
    /// feature that does not work.
    @Test("Replaying the owner's real week interrupts a handful of times, not fifteen")
    func realWeekIsProportionate() {
        var state = State()
        var alerts: [Alert] = []

        // Spread across seven days the way they actually landed: the guardian in
        // warm-afternoon bursts, the safety events scattered.
        let guardianBursts: [Double] = [
            60, 62, 64, // day 1 afternoon
            1500, 1502, 1504, 1506, // day 2 afternoon
            2900, 2902, 2904, // day 3
        ]
        // All five of the week's SAFETY lines were the SAME sentence — the
        // guardian's floor hold — which is why the expectation below is zero.
        let safetyAt: [Double] = [200, 1600, 3000, 4400, 5800]
        let routineAt: [Double] = [10, 500, 1000, 2000, 3500, 5000]

        for minute in stride(from: 0.0, through: 7200, by: 2) {
            var fresh: [DecisionEvent] = []
            let now = Self.at(minute)
            if guardianBursts.contains(minute) {
                fresh.append(Self.decision("guardian: die 76 °C and nothing cooling — driving the fans", at: now))
            }
            if safetyAt.contains(minute) {
                fresh.append(Self.decision(
                    "SAFETY: system did not resume control — holding fans at minimum RPM ourselves",
                    at: now
                ))
            }
            if routineAt.contains(minute) {
                fresh.append(Self.decision("all fans auto (app connection invalidated)", at: now))
            }
            alerts.append(contentsOf: Self.run(&state, decisions: fresh, at: now))
        }

        let lost = alerts.filter { $0.category == .lostControl }.count
        let guarded = alerts.filter { $0.category == .guardianEngaged }.count

        // Zero, and this is the correction that matters. All five of the week's
        // SAFETY lines were `holdAtFloor` — the guardian holding the fans after
        // a revert because macOS had not taken them back. Ice Cube working.
        // The first version of this feature would have sent five banners for it,
        // and did send one, five seconds after an update.
        #expect(lost == 0, "the week's safety lines were all the routine floor hold")
        #expect(guarded == 3, "ten guardian events in three bursts collapse to three")
        #expect(alerts.count == 3, "fifteen silent events are worth three notifications, not eight")
        #expect(alerts.allSatisfy { $0.category != .fansPinned }, "the fans were never pinned in this replay")
    }

    @Test("A quiet class never suppresses a different one")
    func classesAreIndependent() {
        var state = State()
        Self.run(
            &state,
            decisions: [Self.decision("guardian: die 76 °C and nothing cooling", at: Self.at(0))],
            at: Self.at(0)
        )

        // One minute later, well inside the guardian's quiet period.
        let alerts = Self.run(
            &state,
            decisions: [Self.decision("SAFETY: fan write failed mid-sequence", at: Self.at(1))],
            at: Self.at(1)
        )
        #expect(alerts.count == 1, "a chatty guardian must never mute a safety event")
        #expect(alerts.first?.category == .lostControl)
    }

    @Test("Losing control is allowed to speak sooner than the guardian")
    func safetyHasAShorterQuietPeriod() {
        #expect(ControlAlertRules.safetyEpisodeQuiet < ControlAlertRules.episodeQuiet)

        var state = State()
        let safety = "SAFETY: fan write failed mid-sequence"
        Self.run(&state, decisions: [Self.decision(safety, at: Self.at(0))], at: Self.at(0))
        #expect(Self.run(&state, decisions: [Self.decision(safety, at: Self.at(11))], at: Self.at(11)).count == 1)

        var guardianState = State()
        let guardian = "guardian: die 76 °C and nothing cooling"
        Self.run(&guardianState, decisions: [Self.decision(guardian, at: Self.at(0))], at: Self.at(0))
        #expect(Self.run(&guardianState, decisions: [Self.decision(guardian, at: Self.at(11))], at: Self.at(11))
            .isEmpty)
    }

    // MARK: - Fans pinned

    /// The case this rule exists for: two runaway processes held both fans at
    /// 6800 RPM for 2 h 52 m and nothing said anything.
    @Test("Fans pinned for 45 minutes is worth saying once")
    func pinnedFansSpeakOnce() {
        var state = State()
        let pinned = [Self.fan(actual: 6800), Self.fan(id: 1, actual: 6790)]
        var alerts: [Alert] = []
        for minute in stride(from: 0.0, through: 172, by: 1) {
            alerts += Self.run(&state, fans: pinned, at: Self.at(minute))
        }
        let pinnedAlerts = alerts.filter { $0.category == .fansPinned }
        #expect(pinnedAlerts.count == 1, "2 h 52 m pinned is one notification, not 128")
        #expect(pinnedAlerts.first?.title.contains("45 minutes") == true)
    }

    @Test("A fan dropping off maximum restarts the clock")
    func pinnedRunMustBeContinuous() {
        var state = State()
        // 44 minutes pinned, one minute off, then 44 more: never 45 continuous.
        for minute in stride(from: 0.0, through: 43, by: 1) {
            Self.run(&state, fans: [Self.fan(actual: 6800)], at: Self.at(minute))
        }
        Self.run(&state, fans: [Self.fan(actual: 4000)], at: Self.at(44))
        var alerts: [Alert] = []
        for minute in stride(from: 45.0, through: 88, by: 1) {
            alerts += Self.run(&state, fans: [Self.fan(actual: 6800)], at: Self.at(minute))
        }
        #expect(alerts.isEmpty, "a machine that dips off maximum must not accumulate its way to an alarm")
    }

    /// The other half of "once per run": quiet within a run, but a genuinely
    /// new run is news again. Without this the rule would report a machine's
    /// first bad afternoon and stay silent for every one after it.
    @Test("A separate pinned run is reported again")
    func aNewPinnedRunSpeaksAgain() {
        var state = State()
        var alerts: [Alert] = []
        // Run one: 50 minutes pinned.
        for minute in stride(from: 0.0, through: 50, by: 1) {
            alerts += Self.run(&state, fans: [Self.fan(actual: 6800)], at: Self.at(minute))
        }
        // The fans come down — the condition ended.
        Self.run(&state, fans: [Self.fan(actual: 3000)], at: Self.at(51))
        // Run two, immediately after: inside the 30-minute quiet period, so a
        // time-based gate would swallow this.
        for minute in stride(from: 52.0, through: 100, by: 1) {
            alerts += Self.run(&state, fans: [Self.fan(actual: 6800)], at: Self.at(minute))
        }
        #expect(alerts.filter { $0.category == .fansPinned }.count == 2)
    }

    @Test("A fan below the pinned threshold is not pinned")
    func belowThresholdIsNotPinned() {
        var state = State()
        var alerts: [Alert] = []
        // 94 % of maximum — busy, not pinned.
        for minute in stride(from: 0.0, through: 60, by: 1) {
            alerts += Self.run(&state, fans: [Self.fan(actual: 6392)], at: Self.at(minute))
        }
        #expect(alerts.isEmpty)
    }

    @Test("A fan with no usable range is never called pinned")
    func brokenRangeIsNotPinned() {
        var state = State()
        var alerts: [Alert] = []
        let broken = Fan(id: 0, name: "Left", mode: .forced, actualRPM: 0, targetRPM: 0, minRPM: 0, maxRPM: 0)
        for minute in stride(from: 0.0, through: 60, by: 1) {
            alerts += Self.run(&state, fans: [broken], at: Self.at(minute))
        }
        #expect(alerts.isEmpty, "0 >= 0 * 0.95 is true — a half-failed read must not become an alarm")
    }

    // MARK: - The user's switches

    @Test("A disabled category stays silent", arguments: Alert.Category.allCases)
    func disabledCategoryIsSilent(category: Alert.Category) {
        var state = State()
        let enabled = Set(Alert.Category.allCases).subtracting([category])
        var alerts: [Alert] = []
        for minute in stride(from: 0.0, through: 60, by: 1) {
            alerts += Self.run(
                &state,
                decisions: [
                    Self.decision("SAFETY: fan write failed", at: Self.at(minute)),
                    Self.decision("guardian: die 76 °C and nothing cooling", at: Self.at(minute)),
                ],
                fans: [Self.fan(actual: 6800)],
                at: Self.at(minute),
                enabled: enabled
            )
        }
        #expect(alerts.allSatisfy { $0.category != category })
    }

    @Test("Alert ids are stable within an episode so a redelivery cannot double-post")
    func idsAreStable() {
        var a = State()
        var b = State()
        let event = Self.decision("SAFETY: fan write failed", at: Self.at(0))
        let first = Self.run(&a, decisions: [event], at: Self.at(0))
        let second = Self.run(&b, decisions: [event], at: Self.at(0))
        #expect(first.first?.id == second.first?.id)
    }
}
