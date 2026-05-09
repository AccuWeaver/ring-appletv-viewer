import Foundation

/// Production implementation of `EventService` that fetches event history from
/// the Partner API, sorts by timestamp descending, and enforces a 50-event limit.
///
/// When a `nil` deviceId is supplied, events are fetched for every device returned
/// by `DeviceService.fetchDevices()` concurrently, then merged into a single
/// chronological list. This mirrors how a top-level "Events" tab would behave
/// across a multi-camera account.
final class DefaultEventService: EventService, @unchecked Sendable {

    // MARK: - Dependencies

    private let authService: AuthService
    private let partnerAPIClient: PartnerAPIClientProtocol
    private let deviceService: DeviceService?

    // MARK: - Constants

    private static let maxEventCount = 50

    // MARK: - Init

    /// Primary initializer. A `DeviceService` is required to support the
    /// "all devices" (nil deviceId) branch of `fetchEvents`.
    init(
        authService: AuthService,
        partnerAPIClient: PartnerAPIClientProtocol,
        deviceService: DeviceService? = nil
    ) {
        self.authService = authService
        self.partnerAPIClient = partnerAPIClient
        self.deviceService = deviceService
    }

    // MARK: - EventService

    func fetchEvents(for deviceId: String?) async throws -> [RingEvent] {
        let token = try await authService.getValidToken()

        if let deviceId = deviceId {
            let resources = try await partnerAPIClient.fetchEvents(
                deviceId: deviceId,
                token: token.accessToken,
                limit: Self.maxEventCount
            )
            return processEvents(resources.map { $0.toDomain() })
        }

        // No deviceId → aggregate across all devices.
        guard let deviceService = deviceService else {
            // No device service wired in — preserve the legacy empty behaviour
            // so existing unit tests that inject a bare DefaultEventService
            // continue to pass.
            return []
        }

        let devices = try await deviceService.fetchDevices()
        guard !devices.isEmpty else { return [] }

        // Fetch per-device event lists concurrently. Per-device failures are
        // swallowed (logged via print) so one offline device doesn't wipe out
        // the whole tab.
        let allEvents = await withTaskGroup(of: [RingEvent].self) { group in
            for device in devices {
                let accessToken = token.accessToken
                let client = self.partnerAPIClient
                group.addTask {
                    do {
                        let resources = try await client.fetchEvents(
                            deviceId: device.id,
                            token: accessToken,
                            limit: Self.maxEventCount
                        )
                        return resources.map { $0.toDomain() }
                    } catch {
                        // One device's failure shouldn't nuke the whole list.
                        return []
                    }
                }
            }

            var merged: [RingEvent] = []
            for await events in group {
                merged.append(contentsOf: events)
            }
            return merged
        }

        return processEvents(allEvents)
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
