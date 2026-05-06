import XCTest
@testable import RingAppleTV

@MainActor
final class EventsViewModelTests: XCTestCase {

    private func makeSUT(eventService: MockEventService = MockEventService()) -> (EventsViewModel, MockEventService) {
        let vm = EventsViewModel(eventService: eventService)
        return (vm, eventService)
    }

    private func makeSampleEvents() -> [RingEvent] {
        [
            RingEvent(id: "1", deviceId: "10", eventType: .motion, createdAt: Date().addingTimeInterval(-3600), duration: 30),
            RingEvent(id: "2", deviceId: "10", eventType: .ding, createdAt: Date().addingTimeInterval(-1800), duration: 15),
            RingEvent(id: "3", deviceId: "20", eventType: .motion, createdAt: Date().addingTimeInterval(-900), duration: 20)
        ]
    }

    func testLoadEvents_success_transitionsToLoaded() async {
        let events = makeSampleEvents()
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .success(events)

        await sut.loadEvents()

        guard case .loaded(let loadedEvents) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedEvents.count, 3)
        XCTAssertEqual(mock.fetchEventsCalls.count, 1)
        XCTAssertNil(mock.fetchEventsCalls.first!)
    }

    func testLoadEvents_forSpecificDevice_passesDeviceId() async {
        let events = makeSampleEvents()
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .success(events)

        await sut.loadEvents(for: "10")

        XCTAssertEqual(mock.fetchEventsCalls.first!, "10")
    }

    func testLoadEvents_failure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .failure(PartnerAPIError.networkError("timeout"))

        await sut.loadEvents()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, PartnerAPIError.networkError("timeout").userMessage)
    }

    func testLoadEvents_empty_withRingProtect_showsGenericMessage() async {
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .success([])
        sut.hasRingProtect = true

        await sut.loadEvents()

        guard case .empty(let message) = sut.state else {
            XCTFail("Expected .empty state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "No events recorded yet.")
    }

    func testLoadEvents_empty_withoutRingProtect_showsSubscriptionMessage() async {
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .success([])
        sut.hasRingProtect = false

        await sut.loadEvents()

        guard case .empty(let message) = sut.state else {
            XCTFail("Expected .empty state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "Ring Protect subscription required to view event history.")
    }

    func testRefresh_reloadsEvents() async {
        let events = makeSampleEvents()
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .success(events)

        await sut.refresh(for: "10")

        guard case .loaded(let loadedEvents) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedEvents.count, 3)
        XCTAssertEqual(mock.fetchEventsCalls.first!, "10")
    }

    func testRefresh_withoutDeviceId_passesNil() async {
        let (sut, mock) = makeSUT()
        mock.fetchEventsResult = .success(makeSampleEvents())

        await sut.refresh()

        XCTAssertNil(mock.fetchEventsCalls.first!)
    }
}
