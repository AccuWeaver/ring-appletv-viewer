import Foundation

/// Fetches event history and video URLs for Ring device events.
protocol EventService: Sendable {
    /// Fetch events for a specific device, or all devices if `deviceId` is `nil`.
    /// Results are sorted descending by `createdAt` and capped at 50.
    func fetchEvents(for deviceId: String?) async throws -> [RingEvent]
    /// Retrieve the playback URL for a recorded event. Requires Ring Protect subscription.
    func fetchEventVideoURL(for event: RingEvent) async throws -> URL
}
