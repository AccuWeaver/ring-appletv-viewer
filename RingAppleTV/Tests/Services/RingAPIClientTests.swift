import XCTest
@testable import RingAppleTV

// MARK: - MockURLProtocol

/// Intercepts all URLSession requests and returns configurable responses.
final class MockURLProtocol: URLProtocol {

    /// Handler called for each request. Return (response, data) or throw an error.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Records all requests for verification.
    static var capturedRequests: [URLRequest] = []

    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test Helpers

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func httpResponse(url: String = "https://oauth.ring.com/oauth/token", statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

// MARK: - JSON Fixtures

private let validAuthTokenJSON = """
{
    "access_token": "test_access",
    "refresh_token": "test_refresh",
    "expires_in": 3600,
    "scope": "client",
    "token_type": "Bearer"
}
""".data(using: .utf8)!

private let validDevicesJSON = """
{
    "doorbots": [
        {
            "id": 1,
            "description": "Front Door",
            "kind": "doorbell",
            "firmware_version": "1.2.3",
            "address": "123 Main St",
            "battery_life": "80",
            "features": {"motion_detection": true}
        }
    ],
    "stickup_cams": [
        {
            "id": 2,
            "description": "Backyard Cam",
            "kind": "stickup_cam",
            "firmware_version": null,
            "address": null,
            "battery_life": null,
            "features": null
        }
    ]
}
""".data(using: .utf8)!

private let validStreamSessionJSON = """
{
    "device_id": 42,
    "hls_url": "https://ring.com/stream/42.m3u8",
    "max_duration": 600
}
""".data(using: .utf8)!

private let validEventsJSON = """
[
    {
        "id": 100,
        "device_id": 1,
        "device_name": "Front Door",
        "kind": "motion",
        "created_at": "2025-01-15T10:30:00Z",
        "duration": 30,
        "thumbnail_url": "https://ring.com/thumb/100.jpg",
        "video_available": true
    }
]
""".data(using: .utf8)!

private let validVideoURLJSON = """
{
    "url": "https://ring.com/videos/100.mp4"
}
""".data(using: .utf8)!

// MARK: - RingAPIClientTests

final class RingAPIClientTests: XCTestCase {

    private var sut: DefaultRingAPIClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        sut = DefaultRingAPIClient(session: makeSession())
    }

    override func tearDown() {
        sut = nil
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - authenticate(email:password:) Success

    func testAuthenticateSuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), validAuthTokenJSON)
        }

        let result = try await sut.authenticate(email: "user@example.com", password: "pass123")

        XCTAssertEqual(result.accessToken, "test_access")
        XCTAssertEqual(result.refreshToken, "test_refresh")
        XCTAssertEqual(result.expiresIn, 3600)
        XCTAssertEqual(result.scope, "client")
        XCTAssertEqual(result.tokenType, "Bearer")
    }

    func testAuthenticateRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), validAuthTokenJSON)
        }

        _ = try await sut.authenticate(email: "user@example.com", password: "pass123")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertNotNil(captured)
        XCTAssertEqual(captured?.url?.absoluteString, "https://oauth.ring.com/oauth/token")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let bodyString = String(data: captured!.httpBody!, encoding: .utf8)!
        XCTAssertTrue(bodyString.contains("grant_type=password"))
        XCTAssertTrue(bodyString.contains("username=user%40example.com"))
        XCTAssertTrue(bodyString.contains("client_id=ring_official_ios"))
        XCTAssertTrue(bodyString.contains("scope=client"))
    }

    // MARK: - authenticate(email:password:twoFactorCode:) Success

    func testAuthenticateWith2FASuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), validAuthTokenJSON)
        }

        let result = try await sut.authenticate(email: "user@example.com", password: "pass123", twoFactorCode: "123456")

        XCTAssertEqual(result.accessToken, "test_access")
    }

    func testAuthenticateWith2FARequestHeaders() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), validAuthTokenJSON)
        }

        _ = try await sut.authenticate(email: "user@example.com", password: "pass123", twoFactorCode: "654321")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "2fa-support"), "654321")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "2fa-code"), "654321")
    }

    // MARK: - refreshToken Success

    func testRefreshTokenSuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), validAuthTokenJSON)
        }

        let result = try await sut.refreshToken("old_refresh_token")

        XCTAssertEqual(result.accessToken, "test_access")
        XCTAssertEqual(result.refreshToken, "test_refresh")
    }

    func testRefreshTokenRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), validAuthTokenJSON)
        }

        _ = try await sut.refreshToken("my_refresh")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.url?.absoluteString, "https://oauth.ring.com/oauth/token")
        XCTAssertEqual(captured?.httpMethod, "POST")

        let bodyString = String(data: captured!.httpBody!, encoding: .utf8)!
        XCTAssertTrue(bodyString.contains("grant_type=refresh_token"))
        XCTAssertTrue(bodyString.contains("refresh_token=my_refresh"))
        XCTAssertTrue(bodyString.contains("client_id=ring_official_ios"))
    }


    // MARK: - fetchDevices Success

    func testFetchDevicesSuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/ring_devices", statusCode: 200), validDevicesJSON)
        }

        let devices = try await sut.fetchDevices(token: "bearer_token")

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, 1)
        XCTAssertEqual(devices[0].description, "Front Door")
        XCTAssertEqual(devices[0].kind, "doorbell")
        XCTAssertEqual(devices[1].id, 2)
        XCTAssertEqual(devices[1].description, "Backyard Cam")
        XCTAssertEqual(devices[1].kind, "stickup_cam")
    }

    func testFetchDevicesRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/ring_devices", statusCode: 200), validDevicesJSON)
        }

        _ = try await sut.fetchDevices(token: "my_token")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.ring.com/clients_api/ring_devices")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer my_token")
    }

    func testFetchDevicesEmptyResponse() async throws {
        let emptyJSON = "{}".data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/ring_devices", statusCode: 200), emptyJSON)
        }

        let devices = try await sut.fetchDevices(token: "token")
        XCTAssertTrue(devices.isEmpty)
    }

    // MARK: - requestLiveStream Success

    func testRequestLiveStreamSuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/doorbots/42/live_view", statusCode: 200), validStreamSessionJSON)
        }

        let session = try await sut.requestLiveStream(deviceId: 42, token: "token")

        XCTAssertEqual(session.deviceId, 42)
        XCTAssertEqual(session.hlsURL, "https://ring.com/stream/42.m3u8")
        XCTAssertEqual(session.maxDuration, 600)
    }

    func testRequestLiveStreamRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/doorbots/42/live_view", statusCode: 200), validStreamSessionJSON)
        }

        _ = try await sut.requestLiveStream(deviceId: 42, token: "stream_token")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.ring.com/clients_api/doorbots/42/live_view")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer stream_token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - fetchEvents Success

    func testFetchEventsSuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/doorbots/1/history", statusCode: 200), validEventsJSON)
        }

        let events = try await sut.fetchEvents(deviceId: 1, token: "token", limit: 50)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, 100)
        XCTAssertEqual(events[0].deviceId, 1)
        XCTAssertEqual(events[0].deviceName, "Front Door")
        XCTAssertEqual(events[0].kind, "motion")
        XCTAssertTrue(events[0].videoAvailable)
    }

    func testFetchEventsRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/doorbots/5/history", statusCode: 200), validEventsJSON)
        }

        _ = try await sut.fetchEvents(deviceId: 5, token: "ev_token", limit: 25)

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertNotNil(captured)
        XCTAssertTrue(captured!.url!.absoluteString.contains("https://api.ring.com/clients_api/doorbots/5/history"))
        XCTAssertTrue(captured!.url!.absoluteString.contains("limit=25"))
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer ev_token")
    }

    // MARK: - fetchEventVideoURL Success

    func testFetchEventVideoURLSuccess() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/dings/100/share/play", statusCode: 200), validVideoURLJSON)
        }

        let url = try await sut.fetchEventVideoURL(eventId: 100, token: "token")

        XCTAssertEqual(url.absoluteString, "https://ring.com/videos/100.mp4")
    }

    func testFetchEventVideoURLRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(url: "https://api.ring.com/clients_api/dings/200/share/play", statusCode: 200), validVideoURLJSON)
        }

        _ = try await sut.fetchEventVideoURL(eventId: 200, token: "vid_token")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.ring.com/clients_api/dings/200/share/play")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer vid_token")
    }

    func testFetchEventVideoURLInvalidURL() async throws {
        let badJSON = """
        { "url": "" }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await sut.fetchEventVideoURL(eventId: 1, token: "token")
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        }
    }


    // MARK: - HTTP Error Mapping

    func testAuthenticate401ThrowsInvalidCredentials() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 401), Data())
        }

        do {
            _ = try await sut.authenticate(email: "bad@example.com", password: "wrong")
            XCTFail("Expected invalidCredentials error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticate412ThrowsTwoFactorRequired() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 412), Data())
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected twoFactorRequired error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .twoFactorRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticate429ThrowsRateLimited() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 429), Data())
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected rateLimited error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticate500ThrowsServerError() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 500), Data())
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected serverError")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .serverError(500))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticate503ThrowsServerError() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 503), Data())
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected serverError")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .serverError(503))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchDevices401ThrowsInvalidCredentials() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 401), Data())
        }

        do {
            _ = try await sut.fetchDevices(token: "expired")
            XCTFail("Expected invalidCredentials")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestLiveStream429ThrowsRateLimited() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 429), Data())
        }

        do {
            _ = try await sut.requestLiveStream(deviceId: 1, token: "token")
            XCTFail("Expected rateLimited")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEvents500ThrowsServerError() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 500), Data())
        }

        do {
            _ = try await sut.fetchEvents(deviceId: 1, token: "token", limit: 10)
            XCTFail("Expected serverError")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .serverError(500))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnknownStatusCodeThrowsUnknown() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 418), Data())
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected unknown error")
        } catch let error as RingAPIError {
            if case .unknown(let msg) = error {
                XCTAssertTrue(msg.contains("418"))
            } else {
                XCTFail("Expected unknown error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Network Errors

    func testNetworkErrorThrowsNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error {
                // expected
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkTimeoutThrowsNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await sut.fetchDevices(token: "token")
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error {
                // expected
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkErrorOnRefreshToken() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.networkConnectionLost)
        }

        do {
            _ = try await sut.refreshToken("token")
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error {
                // expected
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkErrorOnLiveStream() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotFindHost)
        }

        do {
            _ = try await sut.requestLiveStream(deviceId: 1, token: "token")
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error {
                // expected
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }


    // MARK: - JSON Parsing Errors

    func testAuthenticateInvalidJSONThrowsDecodingError() async {
        let badJSON = "not json".data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchDevicesInvalidJSONThrowsDecodingError() async {
        let badJSON = "[invalid]".data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await sut.fetchDevices(token: "token")
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEventsInvalidJSONThrowsDecodingError() async {
        let badJSON = "{}".data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await sut.fetchEvents(deviceId: 1, token: "token", limit: 10)
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestLiveStreamInvalidJSONThrowsDecodingError() async {
        let badJSON = "[]".data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await sut.requestLiveStream(deviceId: 1, token: "token")
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshTokenInvalidJSONThrowsDecodingError() async {
        let badJSON = "null".data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await sut.refreshToken("token")
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticateMissingFieldsThrowsDecodingError() async {
        let partialJSON = """
        { "access_token": "test" }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), partialJSON)
        }

        do {
            _ = try await sut.authenticate(email: "user@example.com", password: "pass")
            XCTFail("Expected decodingError")
        } catch let error as RingAPIError {
            if case .decodingError = error {
                // expected
            } else {
                XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - DevicesWrapper Edge Cases

    func testFetchDevicesWithOnlyAuthorizedDoorbots() async throws {
        let json = """
        {
            "authorized_doorbots": [
                {
                    "id": 10,
                    "description": "Auth Doorbell",
                    "kind": "doorbell_pro",
                    "firmware_version": null,
                    "address": null,
                    "battery_life": null,
                    "features": null
                }
            ]
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), json)
        }

        let devices = try await sut.fetchDevices(token: "token")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, 10)
        XCTAssertEqual(devices[0].kind, "doorbell_pro")
    }

    func testFetchDevicesWithAllCameras() async throws {
        let json = """
        {
            "all_cameras": [
                {
                    "id": 20,
                    "description": "All Cam",
                    "kind": "indoor_cam",
                    "firmware_version": null,
                    "address": null,
                    "battery_life": null,
                    "features": null
                }
            ]
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), json)
        }

        let devices = try await sut.fetchDevices(token: "token")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, 20)
    }

    // MARK: - Auth Token Response Conversion

    func testAuthTokenResponseNilScope() async throws {
        let json = """
        {
            "access_token": "a",
            "refresh_token": "r",
            "expires_in": 7200,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 200), json)
        }

        let result = try await sut.authenticate(email: "user@example.com", password: "pass")
        XCTAssertNil(result.scope)
        XCTAssertEqual(result.expiresIn, 7200)
    }

    // MARK: - Error on fetchEventVideoURL

    func testFetchEventVideoURL401ThrowsInvalidCredentials() async {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 401), Data())
        }

        do {
            _ = try await sut.fetchEventVideoURL(eventId: 1, token: "bad")
            XCTFail("Expected invalidCredentials")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEventVideoURLNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await sut.fetchEventVideoURL(eventId: 1, token: "token")
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error {
                // expected
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
