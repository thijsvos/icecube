// RingBuffer.swift — fixed-capacity FIFO storage for chart history: O(1) append, oldest-first readout.

import Foundation

/// A fixed-capacity ring: appending beyond `capacity` overwrites the oldest
/// element. Backing store for every chart series (1 sample/s × 3600 = 60 min),
/// so memory is bounded no matter how long the app runs.
public struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: ContiguousArray<Element?>
    /// Index the next append writes to.
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    /// A ring holding the newest `capacity` elements.
    ///
    /// - Precondition: `capacity > 0`. A zero-capacity ring stores nothing, and its
    ///   `head` arithmetic divides by zero — so this traps loudly rather than
    ///   silently becoming a black hole for every sample the charts append.
    public init(capacity: Int) {
        precondition(capacity > 0, "a zero-capacity ring buffer stores nothing")
        self.capacity = capacity
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    public var isEmpty: Bool {
        count == 0
    }

    /// Appends, overwriting the oldest element once full. O(1).
    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// All stored elements, oldest first. O(count).
    public var elements: [Element] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity * 2) % capacity
        return (0 ..< count).compactMap { storage[(start + $0) % capacity] }
    }
}
