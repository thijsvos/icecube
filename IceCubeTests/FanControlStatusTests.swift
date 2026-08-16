// FanControlStatusTests.swift — all twelve registration × connection pairs, so two surfaces cannot drift apart.

import Foundation
import Testing

@MainActor
@Suite("FanControlStatus — is fan control working?")
struct FanControlStatusTests {
    private static let registrations: [HelperManager.Registration] =
        [.unknown, .notRegistered, .requiresApproval, .enabled]
    private static let connections: [HelperManager.Connection] =
        [.disconnected, .connected(version: "20"), .versionMismatch(helper: "19")]

    private func summary(
        _ registration: HelperManager.Registration,
        _ connection: HelperManager.Connection = .disconnected
    ) -> FanControlStatus.Summary {
        FanControlStatus.summary(registration: registration, connection: connection)
    }

    // MARK: The truth table

    /// Registration is decisive. A connection state is meaningless while the
    /// service is not approved, and reading it anyway is how "connecting…" ends
    /// up on screen for a service that was never installed.
    @Test("Before approval the connection state is ignored entirely")
    func registrationWinsBeforeApproval() {
        for connection in Self.connections {
            #expect(summary(.unknown, connection) == .off)
            #expect(summary(.notRegistered, connection) == .off)
            #expect(summary(.requiresApproval, connection) == .awaitingApproval)
        }
    }

    @Test("Once enabled, the connection decides")
    func connectionDecidesWhenEnabled() {
        #expect(summary(.enabled, .connected(version: "20")) == .on)
        #expect(summary(.enabled, .versionMismatch(helper: "19")) == .updateNeeded)
        #expect(summary(.enabled, .disconnected) == .starting)
    }

    /// Twelve pairs, and every one must land somewhere. The point of collapsing
    /// them here is that a thirteenth (a new `Registration` case) becomes a
    /// compile error in one place rather than a silently unhandled combination
    /// in two views.
    @Test("Every one of the twelve pairs classifies")
    func allPairsCovered() {
        var seen: Set<FanControlStatus.Summary> = []
        for registration in Self.registrations {
            for connection in Self.connections {
                seen.insert(summary(registration, connection))
            }
        }
        #expect(seen.count == FanControlStatus.Summary.allCases.count, "a state is unreachable: \(seen)")
    }

    // MARK: What each surface says

    /// `.starting` is the one state that resolves itself. Everything else needs
    /// the user, and a surface that offers no button for those is a dead end.
    @Test("Starting is the only unactionable state that is not already working")
    func actionabilityIsHonest() {
        #expect(FanControlStatus.Summary.starting.needsUserAction == false)
        #expect(FanControlStatus.Summary.on.needsUserAction == false)
        for state in [FanControlStatus.Summary.off, .awaitingApproval, .updateNeeded] {
            #expect(state.needsUserAction, "\(state) leaves the user stuck with nothing to press")
        }
    }

    @Test("Every state has distinct, non-empty Settings wording")
    func settingsWordingIsDistinct() {
        let texts = FanControlStatus.Summary.allCases.map(\.settingsText)
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == texts.count, "two states read identically in Settings")
    }

    /// The vocabulary rule Settings states outright: a user does not know what a
    /// helper or a daemon is. `SetupFlowTests` enforces the same list on the
    /// setup flow, and `ControlStatusTests` on the popover's status line.
    @Test("No implementation jargon reaches the Settings status line")
    func noJargon() {
        for state in FanControlStatus.Summary.allCases {
            let text = state.settingsText.lowercased()
            for word in ["helper", "daemon", "xpc", "smc", "launchd", "registered"] {
                #expect(!text.contains(word), "\(state) says \"\(state.settingsText)\"")
            }
        }
    }
}
