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

    func closePopover() {
        recorder.record("closePopover")
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

    // MARK: - Closing the popover to open a window

    /// The vendored popover has to be closed explicitly, because SwiftUI's
    /// `@Environment(\.dismiss)` only closes an `NSPopover` while its window is
    /// key — and `showPopover`'s `makeKey()` is best-effort.
    @Test("Opening a window closes the vendored popover")
    func closesTheVendoredPopover() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.apply(.vendored)
        let afterSwap = recorder.calls.count

        coordinator.closeVendoredPopover()

        #expect(Array(recorder.calls.dropFirst(afterSwap)) == ["closePopover"])
    }

    /// THE other test. If this ever records `popoverDisappeared`, the flag goes
    /// false while the popover is still animating out — and `PopoverView` swaps
    /// in its 1 pt placeholder, collapsing the popover to a 380×1 sliver in
    /// front of the user. That is the inverse of the ~17 % CPU bug and it is
    /// just as invisible from the code. A close is reported by
    /// `popoverDidClose`, never by whoever asked for it.
    @Test("Closing the popover for a window never reports it as gone")
    func closingNeverReportsDisappearance() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.apply(.vendored)
        let afterSwap = recorder.calls.count

        coordinator.closeVendoredPopover()

        #expect(!recorder.calls.dropFirst(afterSwap).contains("popoverDisappeared"))
    }

    /// In SwiftUI hosting the vendored controller holds no popover at all, so
    /// routing a close at it would be a silent no-op on the *default*
    /// configuration — the one the bug was reported against. That path is
    /// `PopoverView`'s ambient dismissal instead, and this asserts the
    /// coordinator knows the difference.
    @Test("In SwiftUI hosting, nothing is asked of the vendored item")
    func closingIsVendoredOnly() {
        let (coordinator, recorder) = makeCoordinator()

        coordinator.closeVendoredPopover()

        #expect(recorder.calls.isEmpty)
    }

    /// Two different jobs. A swap pauses the popover (and must clear the flag);
    /// opening a window closes it (and must not). Folding one into the other
    /// would break the exact-order assertions above — deliberately.
    ///
    /// Scoped to the COORDINATOR on purpose. A real swap to `.swiftUI` does
    /// close the popover — `StatusItemController.removeVendoredItem()` calls
    /// `closePopover()` before dropping the item, and that close is load-bearing:
    /// without it an `NSPopover` would be released while still anchored to a
    /// status item that no longer exists. `FakeHost` models only the call, so
    /// what this pins is narrower and is the part that matters here: the
    /// coordinator must not ALSO close it, because the flag-clearing order
    /// asserted above depends on its exact call sequence.
    @Test("The coordinator itself never calls closePopover during a swap")
    func swapDoesNotClosePopover() {
        let (coordinator, recorder) = makeCoordinator()

        coordinator.apply(.vendored)
        coordinator.apply(.swiftUI)

        #expect(!recorder.calls.contains("closePopover"))
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
