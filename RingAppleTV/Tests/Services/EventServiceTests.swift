import XCTest
@testable import RingAppleTV

// MARK: - Test Helpers

private func makeValidToken() -> AuthToken {
    AuthToken(
        accessToken: "test_access",
        refreshToken: "test_refresh",
        expiresAt: Date().addingTimeInterval(3600),
        scope: "client",
        tokenType: "Bearer", clientId: nil
    )
}

private func makeEventResource(
    id: String = "1",
    deviceId: String = "1",
    type: String = "motion",
    createdAt: String = "2026-01-15T10:00:00Z",
    duration: Int? = 30
) -> PartnerEventResource {
    PartnerEventResource(
        id: id,
        deviceId: deviceId,
        type: type,
        createdAt: createdAt,
        duration: duration
    )
}

private func makeEvent(
    id: String = "1",
    createdAt: Date = Date()
) -> RingEvent {
    RingEvent(
        id: id,
        deviceId: "1",
        eventType: .motion,
        createdAt: createdAt,
        duration: 30
    )
}

// MARK: - EventServiceTests

final class EventServiceTests: XCTestCase {

    private var mockAuth: MockAuthService!
    private var mockAPI: MockPartnerAPIClient!
    private var mockDeviceService: MockDeviceService!
    private var sut: DefaultEventService!

    override func setUp() {
        super.setUp()
        mockAuth = MockAuthService()
        mockAPI = MockPartnerAPIClient()
        mockDeviceService = MockDeviceService()
        mockAuth.getValidTokenResult = .success(makeValidToken())
        sut = DefaultEventService(
            authService: mockAuth,
            partnerAPIClient: mockAPI,
            deviceService: mockDeviceService
        )
    }

    override func tearDown() {
        sut = nil
        mockDeviceService = nil
        mockAPI = nil
        mockAuth = nil
        super.tearDown()
    }

    // MARK: - fetchEvents — Success

    func testFetchEventsReturnsEvents() async throws {
        let resources = [
            makeEventResource(id: "1", createdAt: "2026-01-15T10:00:00Z"),
            makeEventResource(id: "2", createdAt: "2026-01-15T11:00:00Z")
        ]
        mockAPI.fetchEventsResult = .success(resources)

        let events = try await sut.fetchEvents(for: "1")

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(mockAuth.getValidTokenCalls, 1)
    }

    func testFetchEventsReturnsSortedDescending() async throws {
        let resources = [
            makeEventResource(id: "1", createdAt: "2026-01-15T08:00:00Z"),
            makeEventResource(id: "2", createdAt: "2026-01-15T12:00:00Z"),
            makeEventResource(id: "3", createdAt: "2026-01-15T10:00:00Z")
        ]
        mockAPI.fetchEventsResult = .success(resources)

        let events = try await sut.fetchEvents(for: "1")

        // Should be sorted descending by createdAt
        for i in 0..<(events.count - 1) {
            XCTAssertGreaterThanOrEqual(events[i].createdAt, events[i + 1].createdAt)
        }
    }

    // MARK: - fetchEvents — Limit

    func testFetchEventsLimitsTo50() async throws {
        let resources = (0..<60).map { i in
            makeEventResource(id: String(i), createdAt: "2026-01-15T\(String(format: "%02d", i % 24)):00:00Z")
        }
        mockAPI.fetchEventsResult = .success(resources)

        let events = try await sut.fetchEvents(for: "1")

        XCTAssertLessThanOrEqual(events.count, 50)
    }

    // MARK: - fetchEvents — Empty

    func testFetchEventsReturnsEmptyWhenNoEvents() async throws {
        mockAPI.fetchEventsResult = .success([])

        let events = try await sut.fetchEvents(for: "1")

        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - fetchEvents — Error

    func testFetchEventsPropagatesAuthError() async {
        mockAuth.getValidTokenResult = .failure(PartnerAPIError.unauthorized)

        do {
            _ = try await sut.fetchEvents(for: "1")
            XCTFail("Expected unauthorized error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEventsPropagatesAPIError() async {
        mockAPI.fetchEventsResult = .failure(PartnerAPIError.networkError("offline"))

        do {
            _ = try await sut.fetchEvents(for: "1")
            XCTFail("Expected networkError")
        } catch let error as PartnerAPIError {
            if case .networkError = error { /* expected */ }
            else { XCTFail("Expected networkError, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - fetchEvents — Nil DeviceId (aggregation)

    func testFetchEventsWithNilDeviceIdReturnsEmptyWhenNoDevices() async throws {
        mockDeviceService.fetchDevicesResult = .success([])

        let events = try await sut.fetchEvents(for: nil)

        XCTAssertTrue(events.isEmpty)
    }

    func testFetchEventsWithNilDeviceIdAggregatesAcrossDevices() async throws {
        let devices = [
            RingDevice(
                id: "1", name: "Front", model: "doorbell", deviceType: .doorbell,
                firmwareVersion: nil, powerSource: .battery, isOnline: true
            ),
            RingDevice(
                id: "2", name: "Back", model: "stickup", deviceType: .stickupCam,
                firmwareVersion: nil, powerSource: .hardwired, isOnline: true
            )
        ]
        mockDeviceService.fetchDevicesResult = .success(devices)
        // Both devices share the same mock result — that's fine, the count is
        // what matters. We end up with 2× events, then sorted/truncated.
        mockAPI.fetchEventsResult = .success([
            makeEventResource(id: "a", deviceId: "1", createdAt: "2026-01-15T10:00:00Z"),
            makeEventResource(id: "b", deviceId: "1", createdAt: "2026-01-15T11:00:00Z")
        ])

        let events = try await sut.fetchEvents(for: nil)

        XCTAssertEqual(events.count, 4, "Expected 2 events per device × 2 devices = 4")
        // Sorted descending by createdAt
        for i in 0..<(events.count - 1) {
            XCTAssertGreaterThanOrEqual(events[i].createdAt, events[i + 1].createdAt)
        }
    }

    func testFetchEventsWithNilDeviceIdCapsAtFiftyAcrossAggregation() async throws {
        // 3 devices × 25 events each = 75, should truncate to 50
        let devices = (1...3).map { i in
            RingDevice(
                id: String(i), name: "d\(i)", model: "doorbell", deviceType: .doorbell,
                firmwareVersion: nil, powerSource: .battery, isOnline: true
            )
        }
        mockDeviceService.fetchDevicesResult = .success(devices)
        let resources = (0..<25).map { i in
            makeEventResource(
                id: String(i),
                createdAt: "2026-01-15T\(String(format: "%02d", i % 24)):00:00Z"
            )
        }
        mockAPI.fetchEventsResult = .success(resources)

        let events = try await sut.fetchEvents(for: nil)

        XCTAssertLessThanOrEqual(events.count, 50)
    }

    // MARK: - fetchEventVideoURL

    func testFetchEventVideoURLReturnsURL() async throws {
        let expectedURL = URL(string: "https://ring.com/video/123.mp4")!
        mockAPI.downloadVideoResult = .success(expectedURL)

        let event = makeEvent()
        let url = try await sut.fetchEventVideoURL(for: event)

        XCTAssertEqual(url, expectedURL)
    }

    func testFetchEventVideoURLPropagatesError() async {
        mockAPI.downloadVideoResult = .failure(PartnerAPIError.notFound)

        do {
            _ = try await sut.fetchEventVideoURL(for: makeEvent())
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    // MARK: - processEvents (static)

    func testProcessEventsSortsDescending() {
        let now = Date()
        let events = [
            makeEvent(id: "1", createdAt: now.addingTimeInterval(-3600)),
            makeEvent(id: "2", createdAt: now),
            makeEvent(id: "3", createdAt: now.addingTimeInterval(-1800))
        ]

        let result = DefaultEventService.processEvents(events)

        XCTAssertEqual(result[0].id, "2")
        XCTAssertEqual(result[1].id, "3")
        XCTAssertEqual(result[2].id, "1")
    }

    func testProcessEventsLimitsTo50() {
        let now = Date()
        let events = (0..<100).map { i in
            makeEvent(id: String(i), createdAt: now.addingTimeInterval(Double(-i * 60)))
        }

        let result = DefaultEventService.processEvents(events)

        XCTAssertEqual(result.count, 50)
    }

    func testProcessEventsKeepsMostRecent() {
        let now = Date()
        let events = (0..<100).map { i in
            makeEvent(id: String(i), createdAt: now.addingTimeInterval(Double(-i * 60)))
        }

        let result = DefaultEventService.processEvents(events)

        // The most recent event (id: 0, createdAt: now) should be first
        XCTAssertEqual(result.first?.id, "0")
    }
}
