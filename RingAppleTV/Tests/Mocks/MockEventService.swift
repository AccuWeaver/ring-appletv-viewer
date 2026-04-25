import Foundation
@testable import RingAppleTV

/// Mock `EventService` with configurable return values and call tracking.
final class MockEventService: EventService {

    // MARK: - fetchEvents

    var fetchEventsResult: Result<[RingEvent], Error> = .success([])
    var fetchEventsCalls: [Int?] = []

    func fetchEvents(for deviceId: Int?) async throws -> [RingEvent] {
        fetchEventsCalls.append(deviceId)
        return try fetchEventsResult.get()
    }

    // MARK: - fetchEventVideoURL

    var fetchEventVideoURLResult: Result<URL, Error> = .failure(RingAPIError.unknown("not configured"))
    var fetchEventVideoURLCalls: [RingEvent] = []

    func fetchEventVideoURL(for event: RingEvent) async throws -> URL {
        fetchEventVideoURLCalls.append(event)
        return try fetchEventVideoURLResult.get()
    }
}
