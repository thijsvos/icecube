// PresenceMonitor.swift — tells the app when the user has stepped away from the Mac, and when they are back.

import AppKit
import CoreGraphics
import Foundation
import IceCubeKit
import os

/// Reports whether someone is at the Mac, and calls back when that changes.
///
/// Extracted as a protocol for the same reason as ``PowerSourceObserving``:
/// the interesting behaviour is what happens *on a transition*, and a test
/// cannot lock the screen. A fake drives both directions in microseconds, so
/// CI never depends on the runner's session state — which on a headless build
/// machine is whatever launchd left it in and would exercise nothing.
protocol PresenceObserving: AnyObject {
    /// Whether someone is at the Mac right now. Read fresh on each call.
    var current: PresencePolicy.Presence { get }
    /// Why, in the user's words: "screen locked", "display asleep", "here".
    /// Goes into the log line and the Settings report, never into a decision.
    var reason: String { get }
    /// Called on the main actor the moment a session signal arrives, so the
    /// rule can act immediately instead of waiting for the next poll.
    ///
    /// Optional in the honest sense: whoever sets it must ALSO keep polling
    /// ``current``, exactly as with the power source. Nothing guarantees a
    /// notification is delivered, and the 5 s poll is the floor.
    var onChange: (@MainActor () -> Void)? { get set }
    /// Begins observing. Safe to call more than once.
    func start()
}

// No default implementations, for the reason ``PowerSourceObserving`` gives:
// a default `start()` that does nothing, or an `onChange` that is silently
// dropped, is a monitor that never fires with the compiler saying nothing.

/// The real thing: macOS's own session signals, no polling, no timer.
///
/// **What counts as away.** The screen is locked, the screensaver is running,
/// or the display is asleep — any one of the three. These are the moments the
/// OS itself has decided nobody is looking, which is exactly the judgement
/// this feature needs and must not second-guess. **Deliberately no idle
/// timer**: macOS already has one (the display-sleep timer) and it honours
/// apps that keep the display awake — a movie, a presentation, a screen
/// share. A second timer in Ice Cube would not, and would spin the fans up
/// twenty minutes into a film. Users who want "away after ten minutes" set
/// display sleep to ten minutes.
///
/// **Where the signals come from.** Display sleep/wake are documented
/// `NSWorkspace` notifications. Lock/unlock and screensaver start/stop are
/// distributed notifications that macOS has posted under the same names since
/// 10.5; they are not in a header, so they are strings here, and if Apple ever
/// stopped posting them the feature would degrade to display sleep alone
/// rather than misfire. The lock flag is also re-read from the session
/// dictionary at start and on every system wake, because a notification
/// missed during sleep must not leave "locked" stuck on.
///
/// Every signal logs. If a transition is ever missed, the log has to say
/// whether the notification never arrived or the derivation was wrong.
final class PresenceMonitor: PresenceObserving {
    var onChange: (@MainActor () -> Void)?
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")
    private var isLocked = false
    private var isScreensaverRunning = false
    private var isDisplayAsleep = false
    private var tasks: [Task<Void, Never>] = []
    private var lastReported: PresencePolicy.Presence?

    var current: PresencePolicy.Presence {
        isLocked || isScreensaverRunning || isDisplayAsleep ? .away : .present
    }

    var reason: String {
        if isLocked {
            return "screen locked"
        }
        if isScreensaverRunning {
            return "screensaver running"
        }
        if isDisplayAsleep {
            return "display asleep"
        }
        return "here"
    }

    func start() {
        guard tasks.isEmpty else { return }
        resync(because: "start")
        lastReported = current

        let workspace = NSWorkspace.shared.notificationCenter
        let session = DistributedNotificationCenter.default()
        // One task per signal, each an AsyncSequence rather than addObserver:
        // ending the `for await` deregisters the observation, so cancelling
        // the stored tasks from `deinit` is all the teardown there is, and the
        // loop bodies run in this type's MainActor isolation with no hop.
        // Element ignored throughout: Notification is not Sendable.
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.isDisplayAsleep = true
            self?.changed("display asleep")
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.isDisplayAsleep = false
            self?.changed("display awake")
        }
        // A wake is where a lock notification is most likely to have been
        // missed — the Mac slept with the screen locked, or locked itself on
        // the way down — so the flag is read back from the session rather than
        // trusted.
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.resync(because: "system wake")
            self?.changed("system wake")
        }
        observe(session, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.isLocked = true
            self?.changed("screen locked")
        }
        observe(session, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.isLocked = false
            self?.changed("screen unlocked")
        }
        observe(session, Notification.Name("com.apple.screensaver.didstart")) { [weak self] in
            self?.isScreensaverRunning = true
            self?.changed("screensaver started")
        }
        observe(session, Notification.Name("com.apple.screensaver.didstop")) { [weak self] in
            self?.isScreensaverRunning = false
            self?.changed("screensaver stopped")
        }
        log.notice("presence: watching lock, screensaver and display sleep (poll backstop every 5 s)")
    }

    deinit {
        // Task.cancel() is nonisolated and safe to call from deinit.
        for task in tasks {
            task.cancel()
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor () -> Void
    ) {
        tasks.append(Task {
            for await _ in center.notifications(named: name) {
                handle()
            }
        })
    }

    /// Reads the facts that can be read, so a stale flag cannot survive.
    ///
    /// `CGSSessionScreenIsLocked` is not a documented key, but it is the one
    /// `CGSessionCopyCurrentDictionary` has carried for the lock state for as
    /// long as the notification above has existed, and an absent key reads as
    /// unlocked — the failure mode that leaves the fans alone rather than the
    /// one that spins them up. `CGDisplayIsAsleep` is public.
    private func resync(because reason: String) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        if locked != isLocked || asleep != isDisplayAsleep {
            log.notice(
                "presence: resync on \(reason, privacy: .public) — locked \(locked), display asleep \(asleep)"
            )
        }
        isLocked = locked
        isDisplayAsleep = asleep
    }

    private func changed(_ signal: String) {
        let now = current
        log.notice("presence: \(signal, privacy: .public) -> \(now.rawValue, privacy: .public)")
        // Signals that do not flip the derived state (a second lock event, a
        // display wake while still locked) are logged and otherwise inert —
        // the rule is transition-based, so calling back would be harmless,
        // but a callback per non-event makes the log lie about causality.
        guard now != lastReported else { return }
        lastReported = now
        onChange?()
    }
}
