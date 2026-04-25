import Foundation

/// Production implementation of `EventService` that fetches event history from
/// the Ring API, sorts by timestamp descending, and enforces a 50-event limit.
final class DefaultEventService: EventService {

    // MARK: - Dependencies

    private let authService: AuthService
    private let apiClient: RingAPIClient

    // MARK: - Constants

    private static let maxEventCount = 50

    // MARK: - Init

    init(authService: AuthService, apiClient: RingAPIClient) {
        self.authService = authService
        self.apiClient = apiClient
    }

    // MARK: - EventService

    func fetchEvents(for deviceId: Int?) async throws -> [RingEvent] {
        let token = try await authService.getValidToken()
        let id = deviceId ?? 0
        let responses = try await apiClient.fetchEvents(
            deviceId: id,
            token: token.accessToken,
            limit: Self.maxEventCount
        )
        let events = responses.map { $0.toDomain() }
        return processEvents(events)
    }

    func fetchEventVideoURL(for event: RingEvent) async throws -> URL {
        let token = try await authService.getValidToken()
        return try await apiClient.fetchEventVideoURL(eventId: event.id, token: token.accessToken)
    }

    // MARK: - Internal (visible for testing)

    /// Sorts events descending by `createdAt` and limits to 50.
    static func processEvents(_ events: [RingEvent]) -> [RingEvent] {
        let sorted = events.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(maxEventCount))
    }

    private func processEvents(_ events: [RingEvent]) -> [RingEvent] {
        Self.processEvents(events)
    }
}
