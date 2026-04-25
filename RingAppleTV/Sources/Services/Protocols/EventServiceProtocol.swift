import Foundation

/// Fetches event history and video URLs for Ring device events.
protocol EventService {
    func fetchEvents(for deviceId: Int?) async throws -> [RingEvent]
    func fetchEventVideoURL(for event: RingEvent) async throws -> URL
}
