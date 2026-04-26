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

private func makeStreamResponse(deviceId: Int = 1, maxDuration: Int = 600) -> StreamSessionResponse {
    StreamSessionResponse(
        sipServerIp: "52.12.182.65",
        sipServerPort: 15064,
        sipServerTls: true,
        sipSessionId: "test-session",
        sipFrom: "sip:test@ring.com",
        sipTo: "sip:device@52.12.182.65:15064",
        sipToken: "",
        sipEndpoints: nil,
        doorbotId: deviceId,
        expiresIn: maxDuration,
        protocol_: "sip",
        state: "ringing"
    )
}

// MARK: - VideoServiceTests

final class VideoServiceTests: XCTestCase {

    private var mockAuth: MockAuthService!
    private var mockAPI: MockRingAPIClient!
    private var sut: DefaultVideoService!

    override func setUp() {
        super.setUp()
        mockAuth = MockAuthService()
        mockAPI = MockRingAPIClient()
        mockAuth.getValidTokenResult = .success(makeValidToken())
        sut = DefaultVideoService(authService: mockAuth, apiClient: mockAPI)
    }

    override func tearDown() {
        sut = nil
        mockAPI = nil
        mockAuth = nil
        super.tearDown()
    }

    // MARK: - requestLiveStream — Success

    func testRequestLiveStreamReturnsSession() async throws {
        let response = makeStreamResponse(deviceId: 42, maxDuration: 600)
        mockAPI.requestLiveStreamResult = .success(response)

        let session = try await sut.requestLiveStream(for: 42)

        XCTAssertEqual(session.deviceId, 42)
        XCTAssertEqual(session.maxDuration, 600)
        XCTAssertTrue(session.isValid)
        XCTAssertEqual(mockAuth.getValidTokenCalls, 1)
    }

    func testRequestLiveStreamUsesSipSession() async throws {
        mockAPI.requestLiveStreamResult = .success(makeStreamResponse())

        let session = try await sut.requestLiveStream(for: 1)

        XCTAssertEqual(session.sipServerIp, "52.12.182.65")
        XCTAssertTrue(session.isSipSession)
    }

    // MARK: - requestLiveStream — Auth Error

    func testRequestLiveStreamPropagatesAuthError() async {
        mockAuth.getValidTokenResult = .failure(RingAPIError.tokenExpired)

        do {
            _ = try await sut.requestLiveStream(for: 1)
            XCTFail("Expected tokenExpired error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .tokenExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - requestLiveStream — Stream Unavailable (Offline)

    func testRequestLiveStreamPropagatesStreamUnavailable() async {
        mockAPI.requestLiveStreamResult = .failure(RingAPIError.streamUnavailable)

        do {
            _ = try await sut.requestLiveStream(for: 1)
            XCTFail("Expected streamUnavailable error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .streamUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - requestLiveStream — Device Offline

    func testRequestLiveStreamPropagatesDeviceOffline() async {
        mockAPI.requestLiveStreamResult = .failure(RingAPIError.deviceOffline)

        do {
            _ = try await sut.requestLiveStream(for: 1)
            XCTFail("Expected deviceOffline error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .deviceOffline)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - requestLiveStream — Network Error (Timeout)

    func testRequestLiveStreamPropagatesNetworkError() async {
        mockAPI.requestLiveStreamResult = .failure(RingAPIError.networkError("timeout"))

        do {
            _ = try await sut.requestLiveStream(for: 1)
            XCTFail("Expected networkError")
        } catch let error as RingAPIError {
            if case .networkError = error { /* expected */ }
            else { XCTFail("Expected networkError, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - validateStreamSession

    func testValidateStreamSessionReturnsTrueForValidSession() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 600
        )
        XCTAssertTrue(sut.validateStreamSession(session))
    }

    func testValidateStreamSessionReturnsFalseForExpiredSession() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date().addingTimeInterval(-700),
            maxDuration: 600
        )
        XCTAssertFalse(sut.validateStreamSession(session))
    }

    func testValidateStreamSessionReturnsFalseForZeroDuration() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 0
        )
        XCTAssertFalse(sut.validateStreamSession(session))
    }
}
