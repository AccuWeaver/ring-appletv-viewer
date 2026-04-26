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

private func makeDeviceResponse(id: Int = 1, description: String = "Front Door", kind: String = "doorbell") -> RingDeviceResponse {
    RingDeviceResponse(
        id: id,
        description: description,
        kind: kind,
        firmwareVersion: "1.0",
        address: nil,
        batteryLife: "80"
    )
}

private func makeDevice(
    id: Int = 1,
    description: String = "Front Door",
    deviceType: RingDevice.DeviceType = .doorbell,
    isOnline: Bool = true
) -> RingDevice {
    RingDevice(
        id: id,
        description: description,
        deviceType: deviceType,
        firmwareVersion: "1.0",
        address: nil,
        batteryLife: 80,
        features: nil,
        isOnline: isOnline
    )
}

// MARK: - DeviceServiceTests

final class DeviceServiceTests: XCTestCase {

    private var mockAuth: MockAuthService!
    private var mockAPI: MockRingAPIClient!
    private var mockCache: MockCacheService!
    private var sut: DefaultDeviceService!

    override func setUp() {
        super.setUp()
        mockAuth = MockAuthService()
        mockAPI = MockRingAPIClient()
        mockCache = MockCacheService()
        mockAuth.getValidTokenResult = .success(makeValidToken())
        sut = DefaultDeviceService(authService: mockAuth, apiClient: mockAPI, cacheService: mockCache)
    }

    override func tearDown() {
        sut = nil
        mockCache = nil
        mockAPI = nil
        mockAuth = nil
        super.tearDown()
    }

    // MARK: - fetchDevices — API

    func testFetchDevicesFromAPIWhenCacheEmpty() async throws {
        let responses = [makeDeviceResponse(id: 1), makeDeviceResponse(id: 2, description: "Back Yard")]
        mockAPI.fetchDevicesResult = .success(responses)

        let devices = try await sut.fetchDevices()

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, 1)
        XCTAssertEqual(devices[1].id, 2)
        XCTAssertEqual(mockAuth.getValidTokenCalls, 1)
    }

    func testFetchDevicesCachesAPIResult() async throws {
        mockAPI.fetchDevicesResult = .success([makeDeviceResponse()])

        _ = try await sut.fetchDevices()

        XCTAssertEqual(mockCache.saveCalls.count, 1)
        XCTAssertEqual(mockCache.saveCalls.first?.key, "ring_devices")
    }

    // MARK: - fetchDevices — Cache

    func testFetchDevicesReturnsCachedDevices() async throws {
        let cached = [makeDevice(id: 10, description: "Cached Device")]
        try mockCache.save(cached, for: "ring_devices", ttl: 300)

        let devices = try await sut.fetchDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, 10)
        // Should not call API
        XCTAssertEqual(mockAuth.getValidTokenCalls, 0)
    }

    // MARK: - fetchDevices — Cache Expiration

    func testFetchDevicesFallsBackToAPIWhenCacheExpired() async throws {
        // Save with 0 TTL so it's immediately expired
        try mockCache.save([makeDevice()], for: "ring_devices", ttl: -1)
        mockAPI.fetchDevicesResult = .success([makeDeviceResponse(id: 99)])

        let devices = try await sut.fetchDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, 99)
        XCTAssertEqual(mockAuth.getValidTokenCalls, 1)
    }

    // MARK: - fetchDevices — Error

    func testFetchDevicesPropagatesAuthError() async {
        mockAuth.getValidTokenResult = .failure(RingAPIError.tokenExpired)

        do {
            _ = try await sut.fetchDevices()
            XCTFail("Expected tokenExpired error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .tokenExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchDevicesPropagatesAPIError() async {
        mockAPI.fetchDevicesResult = .failure(RingAPIError.networkError("offline"))

        do {
            _ = try await sut.fetchDevices()
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error { /* expected */ }
            else { XCTFail("Expected networkError, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - refreshDevices

    func testRefreshDevicesAlwaysCallsAPI() async throws {
        // Pre-populate cache
        try mockCache.save([makeDevice()], for: "ring_devices", ttl: 300)
        mockAPI.fetchDevicesResult = .success([makeDeviceResponse(id: 42)])

        let devices = try await sut.refreshDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, 42)
        XCTAssertEqual(mockAuth.getValidTokenCalls, 1)
    }

    func testRefreshDevicesUpdatesCacheAfterFetch() async throws {
        mockAPI.fetchDevicesResult = .success([makeDeviceResponse()])

        _ = try await sut.refreshDevices()

        XCTAssertTrue(mockCache.saveCalls.contains { $0.key == "ring_devices" })
    }

    // MARK: - filterDevices — All

    func testFilterAllReturnsAllDevices() {
        let devices = [makeDevice(id: 1), makeDevice(id: 2)]
        let result = sut.filterDevices(devices, by: .all)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - filterDevices — Name

    func testFilterByNameMatchesSubstring() {
        let devices = [
            makeDevice(id: 1, description: "Front Door"),
            makeDevice(id: 2, description: "Back Yard"),
            makeDevice(id: 3, description: "Front Porch")
        ]
        let result = sut.filterDevices(devices, by: .name("front"))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.description.lowercased().contains("front") })
    }

    func testFilterByNameNoMatch() {
        let devices = [makeDevice(description: "Front Door")]
        let result = sut.filterDevices(devices, by: .name("garage"))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - filterDevices — Type

    func testFilterByType() {
        let devices = [
            makeDevice(id: 1, deviceType: .doorbell),
            makeDevice(id: 2, deviceType: .stickupCam),
            makeDevice(id: 3, deviceType: .doorbell)
        ]
        let result = sut.filterDevices(devices, by: .type(.doorbell))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.deviceType == .doorbell })
    }

    // MARK: - filterDevices — Status

    func testFilterByStatusOnline() {
        let devices = [
            makeDevice(id: 1, isOnline: true),
            makeDevice(id: 2, isOnline: false),
            makeDevice(id: 3, isOnline: true)
        ]
        let result = sut.filterDevices(devices, by: .status(.online))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.isOnline })
    }

    func testFilterByStatusOffline() {
        let devices = [
            makeDevice(id: 1, isOnline: true),
            makeDevice(id: 2, isOnline: false)
        ]
        let result = sut.filterDevices(devices, by: .status(.offline))
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.allSatisfy { !$0.isOnline })
    }

    // MARK: - sortDevices — Name

    func testSortByNameAscending() {
        let devices = [
            makeDevice(id: 1, description: "Charlie"),
            makeDevice(id: 2, description: "Alpha"),
            makeDevice(id: 3, description: "Bravo")
        ]
        let result = sut.sortDevices(devices, by: .nameAscending)
        XCTAssertEqual(result.map(\.description), ["Alpha", "Bravo", "Charlie"])
    }

    func testSortByNameDescending() {
        let devices = [
            makeDevice(id: 1, description: "Alpha"),
            makeDevice(id: 2, description: "Charlie"),
            makeDevice(id: 3, description: "Bravo")
        ]
        let result = sut.sortDevices(devices, by: .nameDescending)
        XCTAssertEqual(result.map(\.description), ["Charlie", "Bravo", "Alpha"])
    }

    // MARK: - sortDevices — Type

    func testSortByType() {
        let devices = [
            makeDevice(id: 1, deviceType: .stickupCam),
            makeDevice(id: 2, deviceType: .doorbell),
            makeDevice(id: 3, deviceType: .indoorCam)
        ]
        let result = sut.sortDevices(devices, by: .type)
        // Sorted by rawValue alphabetically
        for i in 0..<(result.count - 1) {
            XCTAssertLessThanOrEqual(result[i].deviceType.rawValue, result[i + 1].deviceType.rawValue)
        }
    }

    // MARK: - sortDevices — Status

    func testSortByStatusOnlineFirst() {
        let devices = [
            makeDevice(id: 1, isOnline: false),
            makeDevice(id: 2, isOnline: true),
            makeDevice(id: 3, isOnline: false),
            makeDevice(id: 4, isOnline: true)
        ]
        let result = sut.sortDevices(devices, by: .status)
        // Online devices should come first
        let onlineCount = result.filter(\.isOnline).count
        let firstOnline = result.prefix(onlineCount)
        XCTAssertTrue(firstOnline.allSatisfy(\.isOnline))
    }

    // MARK: - sortDevices — Empty

    func testSortEmptyArray() {
        let result = sut.sortDevices([], by: .nameAscending)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - filterDevices — Empty

    func testFilterEmptyArray() {
        let result = sut.filterDevices([], by: .name("test"))
        XCTAssertTrue(result.isEmpty)
    }
}
