// ControlAlertRules.swift — when Ice Cube should interrupt you, and far more importantly when it should not.

import Foundation

/// Decides when the app speaks.
///
/// ## Why this exists
///
/// Ice Cube could tell you it was hot and nothing else. The watchdog could fire,
/// the daemon could hand the fans back, a write could fail, ``FanGuardian`` could
/// take over because macOS had stopped cooling a 77 °C machine — and the only
/// record was a line in a timeline inside a popover you had to open.
///
/// That is not hypothetical. Seven days of the owner's own log, 2026-08-07:
///
///     5 ×  SAFETY: system did not resume control — holding fans at minimum RPM ourselves
///    10 ×  guardian: die 70–77 °C and nothing cooling — driving the fans
///     6 ×  all fans auto (app connection invalidated)
///
/// Fifteen events where the app either lost control or had to rescue the machine
/// itself, and the user was told about none of them.
///
/// ## Why it is a separate, pure type
///
/// The classification is already done — ``DecisionEvent/Kind`` sorts every daemon
/// sentence into eight cases, and the comment on it says *"colouring it as
/// routine would hide the one event class the user most needs to see."* The
/// project already decided which events matter. What was missing is the
/// judgement about **how often it is acceptable to interrupt someone**, and that
/// judgement is the whole risk in this feature: a notifier that fires fifteen
/// times a week gets muted, and a muted notifier is worth less than none.
///
/// So the rules live here, pure, with the clock injected — because "one
/// notification per episode, not one per tick" is a claim about time, and a
/// claim about time that cannot be tested is a claim that will be wrong.
public enum ControlAlertRules {
    // MARK: - Constants, and what sets them

    /// How long a class of event stays quiet after it has spoken once.
    ///
    /// The guardian engaged **ten times in seven days** on the owner's machine,
    /// in bursts as it tracked a warm afternoon. Ten banners for one afternoon is
    /// how this feature would earn itself a permanent mute. Thirty minutes
    /// collapses a burst to one and still reports a genuinely new episode.
    public static let episodeQuiet: TimeInterval = 30 * 60

    /// The safety class is allowed to speak sooner than the guardian class.
    ///
    /// Losing fan control is a state you may need to act on; the guardian
    /// engaging is Ice Cube *working*, and is closer to news than to an alarm.
    public static let safetyEpisodeQuiet: TimeInterval = 10 * 60

    /// A fan this close to its maximum counts as pinned.
    ///
    /// A fraction rather than an RPM, because `maxRPM` is per-machine
    /// (`F{i}Mx`, 6800 on Mac14,9). 5 % of that range is ~340 RPM — wider than
    /// the tachometer wobble at speed and far narrower than any curve step.
    public static let pinnedFraction: Double = 0.95

    /// How long the fans must stay pinned before that is worth saying.
    ///
    /// The case this rule exists for ran for **2 h 52 m** — two runaway
    /// processes holding both fans at 6800 RPM while nothing said anything.
    /// Forty-five minutes is comfortably longer than a legitimate sustained
    /// workload like a long build or an export, and far shorter than the
    /// incident.
    public static let pinnedDuration: TimeInterval = 45 * 60

    // MARK: - What the app may say

    /// One thing worth interrupting someone for.
    public struct Alert: Sendable, Equatable, Identifiable {
        public enum Category: String, Sendable, Equatable, CaseIterable {
            /// Ice Cube lost fan control, or a safety rule overrode the user.
            case lostControl
            /// ``FanGuardian`` is cooling the Mac because macOS was not.
            case guardianEngaged
            /// The fans have been at their maximum for a long time.
            case fansPinned
        }

        public let category: Category
        public let title: String
        public let body: String
        /// Stable within an episode, so a redelivery cannot double-post.
        public let id: String

        public init(category: Category, title: String, body: String, id: String) {
            self.category = category
            self.title = title
            self.body = body
            self.id = id
        }
    }

    // MARK: - The rule engine

    /// Tracks what has already been said, so it is not said again.
    ///
    /// A value type with an explicit `now` on every call rather than a stored
    /// clock: the caller already has the poll's timestamp, and threading it
    /// through is what lets a test compress seven days into a few lines.
    public struct State: Sendable, Equatable {
        /// When each category last spoke.
        private var lastSpoke: [Alert.Category: Date] = [:]
        /// When the fans were first seen pinned in the current run, or `nil`.
        private var pinnedSince: Date?
        /// Whether the **current** pinned run has already been reported.
        ///
        /// Separate from the time-based quiet period, and it has to be. The
        /// decision categories are discrete events, so "speak again if it
        /// recurs 30 minutes later" is right for them. A pinned run is one
        /// continuous condition, and a time-based gate re-fires on it forever:
        /// the first version of this reported the 2 h 52 m incident **five
        /// times**, once every half hour, which is precisely the nagging that
        /// gets a notifier muted.
        private var spokeForThisPinnedRun = false

        public init() {}

        /// Whether `category` is allowed to speak at `now`.
        ///
        /// The quiet period is per category, so a genuine safety event is never
        /// suppressed by a chatty guardian.
        func maySpeak(_ category: Alert.Category, at now: Date) -> Bool {
            guard let last = lastSpoke[category] else { return true }
            let quiet = category == .lostControl ? safetyEpisodeQuiet : episodeQuiet
            return now.timeIntervalSince(last) >= quiet
        }

        mutating func recordSpoke(_ category: Alert.Category, at now: Date) {
            lastSpoke[category] = now
        }

        /// Feeds the fan observation and returns how long they have been pinned.
        ///
        /// Returns `nil` the moment any fan drops off its maximum — the run has
        /// to be **continuous**, or a machine that touches maximum once an hour
        /// would eventually accumulate its way to a false alarm. Dropping off
        /// also re-arms the rule, so the *next* run can be reported.
        mutating func observePinned(_ pinned: Bool, at now: Date) -> TimeInterval? {
            guard pinned else {
                pinnedSince = nil
                spokeForThisPinnedRun = false
                return nil
            }
            guard let since = pinnedSince else {
                pinnedSince = now
                return 0
            }
            return now.timeIntervalSince(since)
        }

        /// Whether the current pinned run may be reported.
        func mayReportPinnedRun() -> Bool {
            !spokeForThisPinnedRun
        }

        mutating func recordPinnedRunReported() {
            spokeForThisPinnedRun = true
        }
    }

    /// Evaluates one poll.
    ///
    /// - Parameters:
    ///   - decisions: **only decisions not seen before.** `HelperManager`
    ///     already dedupes by `id` and already computes exactly this set, so
    ///     passing the whole timeline would re-alert on every poll.
    ///   - fans: the current readings, for the pinned rule.
    ///   - now: the poll's timestamp.
    ///   - state: mutated in place; owns everything that makes this quiet.
    ///   - enabled: the user's per-category switches.
    public static func evaluate(
        freshDecisions decisions: [DecisionEvent],
        fans: [Fan],
        now: Date,
        state: inout State,
        enabled: Set<Alert.Category> = Set(Alert.Category.allCases)
    ) -> [Alert] {
        var alerts: [Alert] = []

        // --- Loss of control, and the guardian ---
        //
        // Deliberately keyed on `DecisionEvent.Kind` rather than on the text.
        // The daemon classified these once, at the moment it made the decision,
        // with documented ordering (`SAFETY:` wins over everything). Re-deriving
        // that here from prose would be a second source of truth for the one
        // question this feature turns on.
        for kind in [DecisionEvent.Kind.safety, .guardian] {
            let category: Alert.Category = kind == .safety ? .lostControl : .guardianEngaged
            guard enabled.contains(category) else { continue }
            guard let event = decisions.last(where: { $0.kind == kind }) else { continue }
            guard state.maySpeak(category, at: now) else { continue }

            state.recordSpoke(category, at: now)
            alerts.append(
                Alert(
                    category: category,
                    title: kind == .safety ? "Ice Cube lost fan control" : "Ice Cube is cooling your Mac",
                    // The daemon's own sentence, verbatim. It was written to be
                    // read by a person — every one of them is prose, not a code
                    // — and paraphrasing it here would be a third place the same
                    // event is described.
                    body: event.text,
                    id: "\(category.rawValue)-\(event.id)"
                )
            )
        }

        // --- Fans pinned at maximum ---
        guard enabled.contains(.fansPinned) else { return alerts }
        let drivable = fans.filter(\.hasUsableRange)
        let pinned = !drivable.isEmpty && drivable.allSatisfy { $0.actualRPM >= $0.maxRPM * pinnedFraction }
        guard let elapsed = state.observePinned(pinned, at: now), elapsed >= pinnedDuration else {
            return alerts
        }
        // Once per *run*, not once per quiet period. The fans staying at maximum
        // is one condition, however long it lasts, and the user cannot act on
        // being told about it a second time.
        guard state.mayReportPinnedRun() else { return alerts }

        state.recordPinnedRunReported()
        let minutes = Int((elapsed / 60).rounded())
        alerts.append(
            Alert(
                category: .fansPinned,
                title: "Your fans have been at maximum for \(minutes) minutes",
                // Points at the window that can actually answer it rather than
                // guessing here. Naming a process would need continuous
                // per-process sampling, which is deliberately gated to
                // window-open-only — see `AppState.diagnosisAppeared()`.
                body: "Open “Why is it hot?” to see what is drawing the power.",
                id: "fans-pinned-\(Int(now.timeIntervalSince1970 / pinnedDuration))"
            )
        )
        return alerts
    }
}
