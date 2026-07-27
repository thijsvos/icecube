// MenuBarModeTests.swift — the hosting swap: which mode is chosen, and the order the swap happens in.

import Foundation
import Testing

/// One shared log, so the *order* of two collaborators' calls can be asserted
/// rather than only that each happened.
@MainActor
private final class Recorder {
    private(set) var calls: [String] = []
    func record(_ call: String) {
        calls.append(call)
    }
}

@MainActor
private final class FakeHost: MenuBarHosting {
    let recorder: Recorder
    init(_ recorder: Recorder) {
        self.recorder = recorder
    }

    func installVendoredItem() {
        recorder.record("install")
    }

    func removeVendoredItem() {
        recorder.record("remove")
    }
}

@MainActor
private final class FakeLifecycle: PopoverLifecycleObserving {
    let recorder: Recorder
    init(_ recorder: Recorder) {
        self.recorder = recorder
    }

    func popoverDisappeared() {
        recorder.record("popoverDisappeared")
    }
}

/// The riskiest part of the vendored menu bar item is not the AppKit code — it
/// is that a swap can leave `AppState.isPopoverVisible` stranded at true. That
/// costs ~17 % sustained CPU with **no visible symptom**: identical UI,
/// identical behaviour, an off-screen window animating its gauges forever.
///
/// These tests exist to make that specific silence impossible.
@Suite("MenuBarMode — choosing a host and swapping safely")
@MainActor
struct MenuBarModeTests {
    private func makeCoordinator() -> (MenuBarModeCoordinator, Recorder) {
        let recorder = Recorder()
        let coordinator = MenuBarModeCoordinator(
            host: FakeHost(recorder), lifecycle: FakeLifecycle(recorder)
        )
        return (coordinator, recorder)
    }

    // MARK: - Which mode

    @Test(
        "The vendored item requires BOTH the preference and a finished setup",
        arguments: [
            (silent: false, isSetUp: false, expected: MenuBarMode.swiftUI),
            (silent: false, isSetUp: true, expected: .swiftUI),
            (silent: true, isSetUp: false, expected: .swiftUI),
            (silent: true, isSetUp: true, expected: .vendored),
        ]
    )
    func resolvesMode(_ c: (silent: Bool, isSetUp: Bool, expected: MenuBarMode)) {
        #expect(
            MenuBarMode.resolve(prefersSilentOptionClick: c.silent, isSetUp: c.isSetUp)
                == c.expected
        )
    }

    /// The setup and version-mismatch prompts hang off the `MenuBarExtra`
    /// label's `.task`. In an `LSUIElement` app with no Dock icon, a half-set-up
    /// user in vendored mode would have no way to reach setup at all.
    @Test("A user who has not finished setup is never moved off the SwiftUI item")
    func unfinishedSetupStaysOnSwiftUI() {
        #expect(
            MenuBarMode.resolve(prefersSilentOptionClick: true, isSetUp: false) == .swiftUI,
            "the only entry point to setup would disappear"
        )
    }

    // MARK: - The swap

    @Test("Nothing happens when the mode is already the one requested")
    func idempotent() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.apply(.swiftUI)
        #expect(recorder.calls.isEmpty)
        #expect(coordinator.isSwiftUIItemInserted)
    }

    /// THE test. The flag must be cleared before anything moves, or an
    /// off-screen popover keeps rendering at ~17 % CPU with nothing to show for
    /// it.
    @Test("Switching to the vendored item pauses the popover first")
    func toVendoredPausesFirst() {
        let (coordinator, recorder) = makeCoordinator()

        coordinator.apply(.vendored)

        #expect(recorder.calls == ["popoverDisappeared", "install"])
        #expect(coordinator.isSwiftUIItemInserted == false)
        #expect(coordinator.mode == .vendored)
    }

    /// The same hazard from the other direction: the SwiftUI popover is
    /// re-inserted, and if the flag is still true its body renders immediately
    /// into a window nobody opened.
    @Test("Switching back to SwiftUI pauses the popover first, then removes ours")
    func toSwiftUIPausesFirst() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.apply(.vendored)

        coordinator.apply(.swiftUI)

        #expect(recorder.calls == ["popoverDisappeared", "install", "popoverDisappeared", "remove"])
        #expect(coordinator.isSwiftUIItemInserted)
        #expect(coordinator.mode == .swiftUI)
    }

    /// Whatever else changes, this must hold: no transition may move an item
    /// without pausing the popover first. Asserted over every transition rather
    /// than by inspection, so a future case cannot be added without one.
    @Test("Every transition pauses the popover before touching an item")
    func everyTransitionPausesFirst() {
        for sequence in [
            [MenuBarMode.vendored],
            [.vendored, .swiftUI],
            [.vendored, .swiftUI, .vendored],
        ] {
            let (coordinator, recorder) = makeCoordinator()
            for mode in sequence {
                coordinator.apply(mode)
            }
            for (index, call) in recorder.calls.enumerated() where call != "popoverDisappeared" {
                #expect(
                    index > 0 && recorder.calls[index - 1] == "popoverDisappeared",
                    "\(call) ran without pausing the popover first, in \(sequence)"
                )
            }
        }
    }

    /// Both status items present at once would show the glyph twice.
    @Test("The two items are never both in the menu bar")
    func neverTwoItems() {
        let (coordinator, recorder) = makeCoordinator()

        coordinator.apply(.vendored)

        // `isSwiftUIItemInserted` is already false by the time ours installs.
        #expect(coordinator.isSwiftUIItemInserted == false)
        #expect(recorder.calls.last == "install")
    }
}
