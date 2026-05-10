import Foundation

/// Manages event history: loading, refreshing, and Ring Protect status.
@MainActor
final class EventsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<[RingEvent]> = .idle
    @Published var hasRingProtect = true
    @Published var devices: [String: RingDevice] = [:]

    // MARK: - Dependencies

    private let eventService: EventService
    private let deviceService: DeviceService?

    // MARK: - Init

    init(eventService: EventService, deviceService: DeviceService? = nil) {
        self.eventService = eventService
        self.deviceService = deviceService
    }

    // MARK: - Actions

    /// Load events, optionally filtered to a specific device.
    func loadEvents(for deviceId: String? = nil) async {
        state = .loading

        do {
            async let eventsFetch = eventService.fetchEvents(for: deviceId)
            if let deviceService {
                async let devicesFetch = deviceService.fetchDevices()
                let (events, deviceList) = try await (eventsFetch, devicesFetch)
                devices = Dictionary(uniqueKeysWithValues: deviceList.map { ($0.id, $0) })
                updateState(with: events)
            } else {
                let events = try await eventsFetch
                updateState(with: events)
            }
        } catch let error as PartnerAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Force refresh events.
    func refresh(for deviceId: String? = nil) async {
        await loadEvents(for: deviceId)
    }

    private func updateState(with events: [RingEvent]) {
        if events.isEmpty {
            if hasRingProtect {
                state = .empty("No events recorded yet.")
            } else {
                state = .empty("Ring Protect subscription required to view event history.")
            }
        } else {
            state = .loaded(events)
        }
    }
}
