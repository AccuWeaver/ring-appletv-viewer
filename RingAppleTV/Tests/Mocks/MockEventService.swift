import Foundation
@testable import RingAppleTV

/// Mock `EventService` with configurable return values and call tracking.
final class MockEventService: EventService, @unchecked Sendable {

    // MARK: - fetchEvents

    var fetchEventsResult: Result<[RingEvent], Error> = .success([])
    var fetchEventsCalls: [String?] = []

    func fetchEvents(for deviceId: String?) async throws -> [RingEvent] {
        fetchEventsCalls.append(deviceId)
        return try fetchEventsResult.get()
    }

    // MARK: - fetchEventVideoURL

    var fetchEventVideoURLResult: Result<URL, Error> = .failure(PartnerAPIError.notFound)
    var fetchEventVideoURLCalls: [RingEvent] = []

    func fetchEventVideoURL(for event: RingEvent) async throws -> URL {
        fetchEventVideoURLCalls.append(event)
        return try fetchEventVideoURLResult.get()
    }
}
