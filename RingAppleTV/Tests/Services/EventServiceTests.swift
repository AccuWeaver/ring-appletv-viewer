import XCTest
@testable import RingAppleTV

// MARK: - Test Helpers

private func makeValidToken() -> AuthToken {
    AuthToken(
        accessToken: "test_access",
        refreshToken: "test_refresh",
        expiresAt: Date().addingTimeInterval(3600),
        scope: "client",
        tokenType: "Bearer"
    )
}

private func makeEventResponse(
    id: Int = 1,
    deviceId: Int = 1,
    kind: String = "motion",
    createdAt: String = "2026-01-15T10:00:00Z",
    videoAvailable: Bool = true
) -> RingEventResponse {
    RingEventResponse(
        id: id,
        deviceId: deviceId,
        deviceName: "Front Door",
        kind: kind,
        createdAt: createdAt,
        duration: 30,
        thumbnailURL: nil,
        videoAvailable: videoAvailable
    )
}

private func makeEvent(
    id: Int = 1,
    createdAt: Date = Date(),
    videoAvailable: Bool = true
) -> RingEvent {
    RingEvent(
        id: id,
        deviceId: 1,
        deviceName: "Front Door",
        eventType: .motion,
        createdAt: createdAt,
        duration: 30,
        thumbnailURL: nil,
        videoAvailable: videoAvailable
    )
}

// MARK: - EventServiceTests

final class EventServiceTests: XCTestCase {

    private var mockAuth: MockAuthService!
    private var mockAPI: MockRingAPIClient!
    private var sut: DefaultEventService!

    override func setUp() {
        super.setUp()
        mockAuth = MockAuthService()
        mockAPI = MockRingAPIClient()
        mockAuth.getValidTokenResult = .success(makeValidToken())
        sut = DefaultEventService(authService: mockAuth, apiClient: mockAPI)
    }

    override func tearDown() {
        sut = nil
        mockAPI = nil
        mockAuth = nil
        super.tearDown()
    }

    // MARK: - fetchEvents — Success

    func testFetchEventsReturnsEvents() async throws {
        let responses = [
            makeEventResponse(id: 1, createdAt: "2026-01-15T10:00:00Z"),
            makeEventResponse(id: 2, createdAt: "2026-01-15T11:00:00Z")
        ]
        mockAPI.fetchEventsResult = .success(responses)

        let events = try await sut.fetchEvents(for: 1)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(mockAuth.getValidTokenCalls, 1)
    }

    func testFetchEventsReturnsSortedDescending() async throws {
        let responses = [
            makeEventResponse(id: 1, createdAt: "2026-01-15T08:00:00Z"),
            makeEventResponse(id: 2, createdAt: "2026-01-15T12:00:00Z"),
            makeEventResponse(id: 3, createdAt: "2026-01-15T10:00:00Z")
        ]
        mockAPI.fetchEventsResult = .success(responses)

        let events = try await sut.fetchEvents(for: 1)

        // Should be sorted descending by createdAt
        for i in 0..<(events.count - 1) {
            XCTAssertGreaterThanOrEqual(events[i].createdAt, events[i + 1].createdAt)
        }
    }

    // MARK: - fetchEvents — Limit

    func testFetchEventsLimitsTo50() async throws {
        let responses = (0..<60).map { i in
            makeEventResponse(id: i, createdAt: "2026-01-15T\(String(format: "%02d", i % 24)):00:00Z")
        }
        mockAPI.fetchEventsResult = .success(responses)

        let events = try await sut.fetchEvents(for: 1)

        XCTAssertLessThanOrEqual(events.count, 50)
    }

    // MARK: - fetchEvents — Empty

    func testFetchEventsReturnsEmptyWhenNoEvents() async throws {
        mockAPI.fetchEventsResult = .success([])

        let events = try await sut.fetchEvents(for: 1)

        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - fetchEvents — Error

    func testFetchEventsPropagatesAuthError() async {
        mockAuth.getValidTokenResult = .failure(RingAPIError.tokenExpired)

        do {
            _ = try await sut.fetchEvents(for: 1)
            XCTFail("Expected tokenExpired error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .tokenExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEventsPropagatesAPIError() async {
        mockAPI.fetchEventsResult = .failure(RingAPIError.networkError("offline"))

        do {
            _ = try await sut.fetchEvents(for: 1)
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error { /* expected */ }
            else { XCTFail("Expected networkError, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - fetchEvents — Nil DeviceId

    func testFetchEventsWithNilDeviceId() async throws {
        mockAPI.fetchEventsResult = .success([makeEventResponse()])

        let events = try await sut.fetchEvents(for: nil)

        XCTAssertEqual(events.count, 1)
    }

    // MARK: - fetchEventVideoURL

    func testFetchEventVideoURLReturnsURL() async throws {
        let expectedURL = URL(string: "https://ring.com/video/123.mp4")!
        mockAPI.fetchEventVideoURLResult = .success(expectedURL)

        let event = makeEvent()
        let url = try await sut.fetchEventVideoURL(for: event)

        XCTAssertEqual(url, expectedURL)
    }

    func testFetchEventVideoURLPropagatesError() async {
        mockAPI.fetchEventVideoURLResult = .failure(RingAPIError.unknown("no video"))

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
            makeEvent(id: 1, createdAt: now.addingTimeInterval(-3600)),
            makeEvent(id: 2, createdAt: now),
            makeEvent(id: 3, createdAt: now.addingTimeInterval(-1800))
        ]

        let result = DefaultEventService.processEvents(events)

        XCTAssertEqual(result[0].id, 2)
        XCTAssertEqual(result[1].id, 3)
        XCTAssertEqual(result[2].id, 1)
    }

    func testProcessEventsLimitsTo50() {
        let now = Date()
        let events = (0..<100).map { i in
            makeEvent(id: i, createdAt: now.addingTimeInterval(Double(-i * 60)))
        }

        let result = DefaultEventService.processEvents(events)

        XCTAssertEqual(result.count, 50)
    }

    func testProcessEventsKeepsMostRecent() {
        let now = Date()
        let events = (0..<100).map { i in
            makeEvent(id: i, createdAt: now.addingTimeInterval(Double(-i * 60)))
        }

        let result = DefaultEventService.processEvents(events)

        // The most recent event (id: 0, createdAt: now) should be first
        XCTAssertEqual(result.first?.id, 0)
    }

    // MARK: - Ring Protect (videoAvailable)

    func testFetchEventsIncludesVideoAvailableFlag() async throws {
        let responses = [
            makeEventResponse(id: 1, videoAvailable: true),
            makeEventResponse(id: 2, videoAvailable: false)
        ]
        mockAPI.fetchEventsResult = .success(responses)

        let events = try await sut.fetchEvents(for: 1)

        let withVideo = events.first { $0.id == 1 }
        let withoutVideo = events.first { $0.id == 2 }
        XCTAssertEqual(withVideo?.videoAvailable, true)
        XCTAssertEqual(withoutVideo?.videoAvailable, false)
    }
}
