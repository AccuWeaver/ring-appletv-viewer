import Foundation

/// Production implementation of `EventService` that fetches event history from
/// the Partner API, sorts by timestamp descending, and enforces a 50-event limit.
final class DefaultEventService: EventService, @unchecked Sendable {

    // MARK: - Dependencies

    private let authService: AuthService
    private let partnerAPIClient: PartnerAPIClientProtocol

    // MARK: - Constants

    private static let maxEventCount = 50

    // MARK: - Init

    init(authService: AuthService, partnerAPIClient: PartnerAPIClientProtocol) {
        self.authService = authService
        self.partnerAPIClient = partnerAPIClient
    }

    // MARK: - EventService

    func fetchEvents(for deviceId: String?) async throws -> [RingEvent] {
        let token = try await authService.getValidToken()
        guard let deviceId = deviceId else {
            return []
        }
        let resources = try await partnerAPIClient.fetchEvents(
            deviceId: deviceId,
            token: token.accessToken,
            limit: Self.maxEventCount
        )
        let events = resources.map { $0.toDomain() }
        return processEvents(events)
    }

    func fetchEventVideoURL(for event: RingEvent) async throws -> URL {
        let token = try await authService.getValidToken()
        return try await partnerAPIClient.downloadVideo(
            deviceId: event.deviceId,
            eventId: event.id,
            token: token.accessToken
        )
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
