import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Generators

private nonisolated(unsafe) let eventTypeGen: Gen<RingEvent.EventType> = Gen<RingEvent.EventType>.fromElements(of: [
    .motion, .ding, .onDemand
])

private nonisolated(unsafe) let eventGen: Gen<RingEvent> = Gen<RingEvent>.compose { c in
    let offsetSeconds = c.generate(using: Int.arbitrary.suchThat { $0 >= 0 && $0 < 172_800 })

    return RingEvent(
        id: String(c.generate(using: Int.arbitrary.suchThat { $0 > 0 })),
        deviceId: String(c.generate(using: Int.arbitrary.suchThat { $0 > 0 })),
        eventType: c.generate(using: eventTypeGen),
        createdAt: Date().addingTimeInterval(-Double(offsetSeconds)),
        duration: c.generate(using: Int?.arbitrary).map { TimeInterval($0) }
    )
}

extension RingEvent: Arbitrary {
    public static var arbitrary: Gen<RingEvent> {
        eventGen
    }
}

/// Generates event lists of varying sizes (0–200).
private nonisolated(unsafe) let eventListGen: Gen<[RingEvent]> = Gen<Int>.fromElements(in: 0...200).flatMap { count in
    Gen<[RingEvent]>.compose { c in
        (0..<count).map { _ in c.generate(using: eventGen) }
    }
}

// MARK: - Property Tests

/// Property-based tests for event processing.
///
/// **Property 7**: After processing, count ≤ 50 and sorted descending by `createdAt`.
final class EventPropertyTests: XCTestCase {

    /// Feature: AppleTVRing, Property 7: Event processing enforces limit and descending order
    func testEventProcessingEnforcesLimitAndDescendingOrder() {
        property("Feature: AppleTVRing, Property 7: Event processing enforces limit and descending order")
            <- forAll(eventListGen) { events -> Bool in
                let processed = DefaultEventService.processEvents(events)

                // Count must be <= 50
                guard processed.count <= 50 else { return false }

                // Count must be <= original count
                guard processed.count <= events.count else { return false }

                // Must be sorted descending by createdAt
                for i in 0..<max(0, processed.count - 1) {
                    guard processed[i].createdAt >= processed[i + 1].createdAt else { return false }
                }

                // If original had > 50 events, result should be exactly 50
                if events.count > 50 {
                    guard processed.count == 50 else { return false }
                }

                // All processed events must exist in the original
                for event in processed {
                    guard events.contains(where: { $0.id == event.id }) else { return false }
                }

                return true
            }
    }
}
