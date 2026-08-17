// InsideLayout.swift — which blocks the cooling schematic draws, for whatever sensors this Mac reports.

import Foundation

/// The elements of the cooling path, chosen from one snapshot's sensors.
///
/// Every decision about *what appears* lives here rather than in the view, for
/// the reason ``CoolingHistoryChartModel`` exists: a diagram whose blocks
/// appear, vanish or reorder between ticks is unreadable, and that is a
/// property of the selection rather than of the drawing.
///
/// Deliberately grouped rather than exhaustive. A Mac14,9 reports a dozen
/// die sensors — `Tp01`, `Tp05`, `Tp09`, `Tp1h` and friends — and a schematic
/// with twelve identical squares on it says less than one labelled CPU. Each
/// silicon class collapses to its **hottest** member, which is the same
/// reduction the curve input and the safety ceiling already use
/// (``Collection/hottestDieCelsius``); named components keep their own blocks
/// because there is exactly one of each and its label carries information.
public enum InsideLayout {
    /// What a block is, which decides where the view puts it.
    public enum Role: String, Sendable, Equatable, CaseIterable {
        /// Die-class silicon — where the heat comes from.
        case source
        /// A named warm component: SSD, battery, wireless. On the board, not
        /// in the heat path, and drawn away from it.
        case component
        /// The airflow sensor standing in for incoming air.
        case intake
        /// The warmest airflow sensor.
        case outflow
    }

    /// One drawn element.
    public struct Block: Sendable, Equatable, Identifiable {
        /// The SMC key for a component, or the class name for a grouped source.
        public let id: String
        public let label: String
        public let celsius: Double
        public let role: Role
        /// How many sensors this block reduced, so the view can say "hottest
        /// of 8" rather than implying a single reading.
        public let sensorCount: Int

        public init(id: String, label: String, celsius: Double, role: Role, sensorCount: Int = 1) {
            self.id = id
            self.label = label
            self.celsius = celsius
            self.role = role
            self.sensorCount = sensorCount
        }
    }

    /// The blocks to draw, in a stable order: sources, then components, then
    /// the air.
    ///
    /// Order is by ``Role`` and then by `id`, never by temperature — sorting a
    /// diagram by its own live values makes the blocks swap places while you
    /// are looking at them, which is the one thing a schematic may not do.
    ///
    /// A class this Mac does not report is **omitted**, not drawn empty. On an
    /// unmapped model the sensors arrive as raw `T***` keys with no curated
    /// labels, and every one of them still lands in the right group, because
    /// grouping goes through ``SMCKeyMaps/classify(_:)`` — the single source of
    /// truth the safety ceiling already depends on.
    public static func blocks(for temperatures: [SensorReading]) -> [Block] {
        var blocks: [Block] = []

        for (sensorClass, label) in Self.sourceClasses {
            let members = temperatures.filter { $0.sensorClass == sensorClass }
            guard let hottest = members.map(\.celsius).max() else { continue }
            blocks.append(Block(
                id: label, label: label, celsius: hottest,
                role: .source, sensorCount: members.count
            ))
        }

        let ambient = temperatures.filter { $0.sensorClass == .ambient }
        for component in ambient.filter({ !SMCKeyMaps.isAirflowKey($0.key) }).sorted(by: { $0.key < $1.key }) {
            blocks.append(Block(
                id: component.key, label: component.label,
                celsius: component.celsius, role: .component
            ))
        }

        blocks.append(contentsOf: airBlocks(ambient.filter { SMCKeyMaps.isAirflowKey($0.key) }))
        return blocks
    }

    /// The silicon groups, in drawing order. CPU first because it is what
    /// heats first and what people look for.
    private static let sourceClasses: [(SMCKeyMaps.SensorClass, String)] = [
        (.cpu, "CPU"),
        (.gpu, "GPU"),
        (.otherDie, "Silicon"),
    ]

    /// Intake and outflow, assigned **by temperature rather than by position**.
    ///
    /// This is an inference and the window says so. `TaLP`/`TaRF` are named for
    /// where they sit — left and right — not for which end of the airflow they
    /// are, and Ice Cube has no way to know which is nearer the vents. Taking
    /// the coolest as the intake reference is the same choice
    /// ``CoolingEfficiency/ambient(from:)`` already documents and relies on:
    /// the sensor least heated by the SoC is the closest available proxy for
    /// incoming air.
    ///
    /// One airflow sensor yields one block, labelled for what it is rather than
    /// split into a pair that would imply a measurement of both ends.
    private static func airBlocks(_ airflow: [SensorReading]) -> [Block] {
        let sorted = airflow.sorted { $0.celsius < $1.celsius }
        guard let coolest = sorted.first else { return [] }
        guard let warmest = sorted.last, sorted.count > 1 else {
            return [Block(id: coolest.key, label: "Airflow", celsius: coolest.celsius, role: .intake)]
        }
        return [
            Block(id: coolest.key, label: "Air in", celsius: coolest.celsius, role: .intake),
            Block(id: warmest.key, label: "Air out", celsius: warmest.celsius, role: .outflow),
        ]
    }
}
