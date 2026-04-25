import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Generators

private let eventTypeGen: Gen<RingEvent.EventType> = Gen<RingEvent.EventType>.fromElements(of: [
    .motion, .ding, .onDemand
])

private let eventGen: Gen<RingEvent> = Gen<RingEvent>.compose { c in
    // Random date within the last 48 hours
    let offsetSeconds = c.generate(using: Int.arbitrary.suchThat { $0 >= 0 && $0 < 172_800 })

    return RingEvent(
        id: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
        deviceId: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
        deviceName: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
        eventType: c.generate(using: eventTypeGen),
        createdAt: Date().addingTimeInterval(-Double(offsetSeconds)),
        duration: c.generate(using: Int?.arbitrary).map { TimeInterval($0) },
        thumbnailURL: nil,
        videoAvailable: c.generate(using: Bool.arbitrary)
    )
}

/// Generates event lists of varying sizes (0–200).
private let eventListGen: Gen<[RingEvent]> = Gen<Int>.fromElements(in: 0...200).flatMap { count in
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
            <- forAll(eventListGen) { (events: [RingEvent]) in
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
