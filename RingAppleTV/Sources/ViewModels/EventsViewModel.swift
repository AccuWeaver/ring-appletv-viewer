import Foundation

/// Manages event history: loading, refreshing, and Ring Protect status.
@MainActor
final class EventsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<[RingEvent]> = .idle
    @Published var hasRingProtect = true

    // MARK: - Dependencies

    nonisolated(unsafe) private let eventService: EventService

    // MARK: - Init

    init(eventService: EventService) {
        self.eventService = eventService
    }

    // MARK: - Actions

    /// Load events, optionally filtered to a specific device.
    func loadEvents(for deviceId: String? = nil) async {
        state = .loading

        do {
            let events = try await eventService.fetchEvents(for: deviceId)

            if events.isEmpty {
                if hasRingProtect {
                    state = .empty("No events recorded yet.")
                } else {
                    state = .empty("Ring Protect subscription required to view event history.")
                }
            } else {
                state = .loaded(events)
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
}
