// DecisionMarkersTests.swift — the chart only marks decisions that happened, and only ones that mean something.

import Foundation
import IceCubeKit
import Testing

@MainActor
@Suite("Decision markers")
struct DecisionMarkersTests {
    private let noon = Date(timeIntervalSince1970: 1_753_000_000)

    private func event(_ kind: DecisionEvent.Kind, at offset: TimeInterval) -> DecisionEvent {
        DecisionEvent(date: noon.addingTimeInterval(offset), kind: kind, text: "\(kind)")
    }

    private var window: ClosedRange<Date> {
        noon ... noon.addingTimeInterval(300)
    }

    @Test("Decisions outside the visible window are dropped, not clamped to its edge")
    func outsideWindow() {
        let events = [
            event(.engaged, at: -3600),
            event(.safety, at: 150),
            event(.engaged, at: 9999),
        ]
        let visible = DecisionMarkers.visible(events, in: window)
        #expect(visible.count == 1)
        #expect(visible.first?.kind == .safety)
    }

    @Test(
        "Only decisions that change who is driving the fans get a line",
        arguments: DecisionEvent.Kind.allCases
    )
    func notableKinds(kind: DecisionEvent.Kind) {
        let visible = DecisionMarkers.visible([event(kind, at: 10)], in: window)
        let expected = kind != .other && kind != .selfTest
        #expect(
            visible.isEmpty != expected,
            "\(kind) should \(expected ? "" : "not ")be drawn — chatter would bury the ceiling trip"
        )
    }

    @Test("Markers keep the daemon's chronological order across redraws")
    func stableOrder() {
        let events = [event(.engaged, at: 10), event(.safety, at: 20), event(.released, at: 30)]
        let dates = DecisionMarkers.visible(events, in: window).map(\.date)
        #expect(dates == events.map(\.date))
    }

    @Test("A chart with no helper draws nothing rather than failing")
    func empty() {
        #expect(DecisionMarkers.visible([], in: window).isEmpty)
    }

    @Test("The window is inclusive at both ends — a decision exactly at the edge is real")
    func inclusiveBounds() {
        let edges = [event(.wake, at: 0), event(.wake, at: 300)]
        #expect(DecisionMarkers.visible(edges, in: window).count == 2)
    }
}
