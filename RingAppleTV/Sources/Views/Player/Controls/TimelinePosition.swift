import Foundation

/// Represents the user's position on the event timeline.
///
/// A `TimelinePosition` is either pinned to the live edge (`eventIndex == nil`)
/// or anchored at a specific event in the `events` list. Events are expected
/// to be ordered ascending by time, so index `0` is the earliest event and
/// `events.count - 1` is the most recent event (immediately before live).
///
/// `movingBack()` and `movingForward()` step through the timeline one event
/// at a time and clamp at the earliest event and the live edge respectively,
/// matching the scrubbing behaviour described in Requirements 3.3, 3.4, 4.4,
/// 4.5, and 4.6.
struct TimelinePosition: Equatable {
    /// Index into `events` for the current position, or `nil` when pinned to
    /// the live edge.
    let eventIndex: Int?

    /// The event list this position is anchored to, ordered ascending by time.
    let events: [RingEvent]

    /// `true` when the position is pinned to the live edge.
    var isAtLiveEdge: Bool { eventIndex == nil }

    /// The event at the current position, or `nil` when at the live edge or
    /// when `eventIndex` is out of bounds.
    var currentEvent: RingEvent? {
        guard let idx = eventIndex, events.indices.contains(idx) else { return nil }
        return events[idx]
    }

    /// Creates a position pinned to the live edge for the given events.
    static func live(events: [RingEvent]) -> TimelinePosition {
        TimelinePosition(eventIndex: nil, events: events)
    }

    /// Returns a new position one event earlier on the timeline.
    ///
    /// - From the live edge, moves to the most-recent event (`events.count - 1`).
    /// - From any event, moves to the preceding index.
    /// - At the earliest event (index `0`), stays at `0`.
    /// - With an empty events list at the live edge, stays at the live edge.
    func movingBack() -> TimelinePosition {
        guard let idx = eventIndex else {
            // At live edge: step back to the most-recent event, if any.
            guard !events.isEmpty else { return self }
            return TimelinePosition(eventIndex: events.count - 1, events: events)
        }
        guard idx > 0 else { return self }
        return TimelinePosition(eventIndex: idx - 1, events: events)
    }

    /// Returns a new position one event later on the timeline.
    ///
    /// - From the live edge, stays at the live edge.
    /// - From the most-recent event (`events.count - 1`), moves to the live edge.
    /// - From any earlier event, moves to the next index.
    func movingForward() -> TimelinePosition {
        guard let idx = eventIndex else { return self }
        let nextIdx = idx + 1
        if nextIdx >= events.count {
            return TimelinePosition(eventIndex: nil, events: events)
        }
        return TimelinePosition(eventIndex: nextIdx, events: events)
    }
}
