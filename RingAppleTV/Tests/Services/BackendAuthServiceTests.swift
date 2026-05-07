import XCTest
@testable import RingAppleTV

// MARK: - Test Helpers

private func makeBackendTokenJSON(
    accessToken: String = "test_access_token",
    tokenType: String = "Bearer",
    expiresAt: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
) -> Data {
    """
    {
        "access_token": "\(accessToken)",
        "token_type": "\(tokenType)",
        "expires_at": "\(expiresAt)"
    }
    """.data(using: .utf8)!
}

private func makeHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

private func makeTestURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func storeTokenInKeychain(_ token: AuthToken, keychain: MockKeychainService) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(token)
    try keychain.save(data, for: "auth_token")
}

private func makeValidToken(expiresIn: TimeInterval = 3600) -> AuthToken {
    AuthToken(
        accessToken: "cached_access_token",
        refreshToken: "",
        expiresAt: Date().addingTimeInterval(expiresIn),
        scope: nil,
        tokenType: "Bearer",
        clientId: nil
    )
}

private func makeNearExpiryToken() -> AuthToken {
    // Expires in 30 seconds — within the 60-second refresh window
    AuthToken(
        accessToken: "near_expiry_access",
        refreshToken: "",
        expiresAt: Date().addingTimeInterval(30),
        scope: nil,
        tokenType: "Bearer",
        clientId: nil
    )
}

private func makeExpiredToken() -> AuthToken {
    AuthToken(
        accessToken: "expired_access",
        refreshToken: "",
        expiresAt: Date().addingTimeInterval(-60),
        scope: nil,
        tokenType: "Bearer",
        clientId: nil
    )
}

// MARK: - BackendAuthServiceTests

final class BackendAuthServiceTests: XCTestCase {

    private var mockKeychain: MockKeychainService!
    private var urlSession: URLSession!
    private var sut: BackendAuthService!

    private let testBaseURL = "https://auth-backend.example.com"
    private let testAPIKey = "test-api-key-12345"
    private let testUserId = "default"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        mockKeychain = MockKeychainService()
        urlSession = makeTestURLSession()
        sut = BackendAuthService(
            backendBaseURL: testBaseURL,
            apiKey: testAPIKey,
            userId: testUserId,
            keychainService: mockKeychain,
            urlSession: urlSession
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        sut = nil
        urlSession = nil
        mockKeychain = nil
        super.tearDown()
    }

    // MARK: - fetchTokenFromBackend() stores token in Keychain after successful fetch

    func testFetchTokenFromBackendStoresTokenInKeychain() async throws {
        let expectedAccessToken = "fresh_access_token"
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))

        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON(accessToken: expectedAccessToken, expiresAt: expiresAt)
            return (response, data)
        }

        let token = try await sut.fetchTokenFromBackend()

        XCTAssertEqual(token.accessToken, expectedAccessToken)

        // Verify token was saved to keychain
        let tokenSaves = mockKeychain.saveCalls.filter { $0.key == "auth_token" }
        XCTAssertEqual(tokenSaves.count, 1)

        // Verify the saved data decodes to the correct token
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let savedToken = try decoder.decode(AuthToken.self, from: tokenSaves[0].data)
        XCTAssertEqual(savedToken.accessToken, expectedAccessToken)
    }

    // MARK: - getValidToken() returns cached token when not near expiry

    func testGetValidTokenReturnsCachedTokenWhenNotNearExpiry() async throws {
        // First, fetch a token to populate the cache
        let cachedAccessToken = "cached_token_value"
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON(
                accessToken: cachedAccessToken,
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            )
            return (response, data)
        }

        _ = try await sut.fetchTokenFromBackend()

        // Reset to track subsequent calls
        MockURLProtocol.capturedRequests = []
        var backendCalled = false
        MockURLProtocol.requestHandler = { _ in
            backendCalled = true
            fatalError("Should not be called")
        }

        // getValidToken should return cached token without calling backend
        let token = try await sut.getValidToken()

        XCTAssertEqual(token.accessToken, cachedAccessToken)
        XCTAssertFalse(backendCalled)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - getValidToken() fetches from backend when token is near expiry (within 60s)

    func testGetValidTokenFetchesFromBackendWhenTokenNearExpiry() async throws {
        // Store a near-expiry token in keychain so it's loaded
        let nearExpiryToken = makeNearExpiryToken()
        try storeTokenInKeychain(nearExpiryToken, keychain: mockKeychain)

        // Create a fresh service that will load from keychain
        let freshService = BackendAuthService(
            backendBaseURL: testBaseURL,
            apiKey: testAPIKey,
            userId: testUserId,
            keychainService: mockKeychain,
            urlSession: urlSession
        )

        let freshAccessToken = "refreshed_from_backend"
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON(
                accessToken: freshAccessToken,
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            )
            return (response, data)
        }

        let token = try await freshService.getValidToken()

        // Should have fetched a fresh token from backend
        XCTAssertEqual(token.accessToken, freshAccessToken)
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    // MARK: - 401 response clears tokens and transitions to unauthenticated

    func testUnauthorizedResponseClearsTokensAndThrows() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 401)
            return (response, Data())
        }

        do {
            _ = try await sut.fetchTokenFromBackend()
            XCTFail("Expected unauthorized error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Verify tokens were cleared
        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertTrue(mockKeychain.deleteCalls.contains("auth_token"))
    }

    func testUnauthorizedResponseClearsCachedToken() async throws {
        // First populate the cache with a valid token
        let validExpiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON(expiresAt: validExpiresAt)
            return (response, data)
        }
        _ = try await sut.fetchTokenFromBackend()
        XCTAssertTrue(sut.isAuthenticated)

        // Now simulate a 401
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 401)
            return (response, Data())
        }

        do {
            _ = try await sut.fetchTokenFromBackend()
            XCTFail("Expected unauthorized error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .unauthorized)
        }

        XCTAssertFalse(sut.isAuthenticated)
    }

    // MARK: - API key is included in Authorization header

    func testAPIKeyIncludedInAuthorizationHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON()
            return (response, data)
        }

        _ = try await sut.fetchTokenFromBackend()

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let capturedRequest = MockURLProtocol.capturedRequests[0]
        let authHeader = capturedRequest.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer \(testAPIKey)")
    }

    func testRequestURLContainsUserIdParameter() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON()
            return (response, data)
        }

        _ = try await sut.fetchTokenFromBackend()

        let capturedRequest = MockURLProtocol.capturedRequests[0]
        let urlString = capturedRequest.url!.absoluteString
        XCTAssertTrue(urlString.contains("user_id=\(testUserId)"))
    }

    func testRequestUsesGETMethod() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON()
            return (response, data)
        }

        _ = try await sut.fetchTokenFromBackend()

        let capturedRequest = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(capturedRequest.httpMethod, "GET")
    }

    // MARK: - BackendTokenResponse.toDomain() correctly converts ISO 8601 dates

    func testToDomainConvertsISO8601DateWithFractionalSeconds() {
        let response = BackendTokenResponse(
            accessToken: "token_123",
            tokenType: "Bearer",
            expiresAt: "2025-06-15T12:30:45.123Z"
        )

        let token = response.toDomain()

        XCTAssertEqual(token.accessToken, "token_123")
        XCTAssertEqual(token.tokenType, "Bearer")
        XCTAssertEqual(token.refreshToken, "")

        // Verify the date was parsed correctly
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedDate = formatter.date(from: "2025-06-15T12:30:45.123Z")!
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testToDomainConvertsISO8601DateWithoutFractionalSeconds() {
        let response = BackendTokenResponse(
            accessToken: "token_456",
            tokenType: "Bearer",
            expiresAt: "2025-12-31T23:59:59Z"
        )

        let token = response.toDomain()

        XCTAssertEqual(token.accessToken, "token_456")

        let formatter = ISO8601DateFormatter()
        let expectedDate = formatter.date(from: "2025-12-31T23:59:59Z")!
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testToDomainFallsBackToCurrentDateForInvalidISO8601() {
        let response = BackendTokenResponse(
            accessToken: "token_789",
            tokenType: "Bearer",
            expiresAt: "not-a-valid-date"
        )

        let beforeCall = Date()
        let token = response.toDomain()
        let afterCall = Date()

        XCTAssertEqual(token.accessToken, "token_789")
        // Should fall back to Date() for invalid date strings
        XCTAssertGreaterThanOrEqual(token.expiresAt, beforeCall)
        XCTAssertLessThanOrEqual(token.expiresAt, afterCall)
    }

    func testToDomainSetsRefreshTokenToEmpty() {
        let response = BackendTokenResponse(
            accessToken: "any_token",
            tokenType: "Bearer",
            expiresAt: "2025-06-15T12:00:00Z"
        )

        let token = response.toDomain()

        XCTAssertEqual(token.refreshToken, "")
        XCTAssertNil(token.scope)
        XCTAssertNil(token.clientId)
    }

    // MARK: - Additional Error Cases

    func testFetchTokenFromBackendThrowsNotFoundOn404() async {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 404)
            return (response, Data())
        }

        do {
            _ = try await sut.fetchTokenFromBackend()
            XCTFail("Expected notFound error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFetchTokenFromBackendThrowsServerErrorOn500() async {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 500)
            return (response, Data())
        }

        do {
            _ = try await sut.fetchTokenFromBackend()
            XCTFail("Expected serverError")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .serverError(500))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFetchTokenFromBackendThrowsNetworkErrorOnFailure() async {
        MockURLProtocol.requestHandler = { _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
            ])
        }

        do {
            _ = try await sut.fetchTokenFromBackend()
            XCTFail("Expected networkError")
        } catch let error as PartnerAPIError {
            if case .networkError = error {
                // Expected
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - getValidToken with keychain token

    func testGetValidTokenReturnsKeychainTokenWhenNotNearExpiry() async throws {
        let validToken = makeValidToken(expiresIn: 3600)
        try storeTokenInKeychain(validToken, keychain: mockKeychain)

        // Create fresh service (no in-memory cache)
        let freshService = BackendAuthService(
            backendBaseURL: testBaseURL,
            apiKey: testAPIKey,
            userId: testUserId,
            keychainService: mockKeychain,
            urlSession: urlSession
        )

        var backendCalled = false
        MockURLProtocol.requestHandler = { _ in
            backendCalled = true
            fatalError("Should not be called")
        }

        let token = try await freshService.getValidToken()

        XCTAssertEqual(token.accessToken, validToken.accessToken)
        XCTAssertFalse(backendCalled)
    }

    func testGetValidTokenFetchesFromBackendWhenTokenExpired() async throws {
        let expiredToken = makeExpiredToken()
        try storeTokenInKeychain(expiredToken, keychain: mockKeychain)

        let freshService = BackendAuthService(
            backendBaseURL: testBaseURL,
            apiKey: testAPIKey,
            userId: testUserId,
            keychainService: mockKeychain,
            urlSession: urlSession
        )

        let freshAccessToken = "new_token_after_expiry"
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let response = makeHTTPResponse(url: url, statusCode: 200)
            let data = makeBackendTokenJSON(
                accessToken: freshAccessToken,
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            )
            return (response, data)
        }

        let token = try await freshService.getValidToken()

        XCTAssertEqual(token.accessToken, freshAccessToken)
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }
}
