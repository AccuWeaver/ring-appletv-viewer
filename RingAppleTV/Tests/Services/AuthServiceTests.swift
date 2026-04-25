import XCTest
@testable import RingAppleTV

// MARK: - Test Helpers

private func makeValidTokenResponse(expiresIn: Int = 3600) -> AuthTokenResponse {
    AuthTokenResponse(
        accessToken: "access_\(UUID().uuidString)",
        refreshToken: "refresh_\(UUID().uuidString)",
        expiresIn: expiresIn,
        scope: "client",
        tokenType: "Bearer"
    )
}

private func makeExpiredToken() -> AuthToken {
    AuthToken(
        accessToken: "expired_access",
        refreshToken: "expired_refresh",
        expiresAt: Date().addingTimeInterval(-60),
        scope: "client",
        tokenType: "Bearer"
    )
}

private func makeValidToken(expiresIn: TimeInterval = 3600) -> AuthToken {
    AuthToken(
        accessToken: "valid_access",
        refreshToken: "valid_refresh",
        expiresAt: Date().addingTimeInterval(expiresIn),
        scope: "client",
        tokenType: "Bearer"
    )
}

private func makeNeedsRefreshToken() -> AuthToken {
    // Expires in 2 minutes — within the 5-minute refresh window
    AuthToken(
        accessToken: "soon_access",
        refreshToken: "soon_refresh",
        expiresAt: Date().addingTimeInterval(120),
        scope: "client",
        tokenType: "Bearer"
    )
}

/// Stores a token in the mock keychain using the same encoding DefaultAuthService uses.
private func storeTokenInKeychain(_ token: AuthToken, keychain: MockKeychainService) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(token)
    try keychain.save(data, for: "auth_token")
}

// MARK: - AuthServiceTests

final class AuthServiceTests: XCTestCase {

    private var mockAPI: MockRingAPIClient!
    private var mockKeychain: MockKeychainService!
    private var sut: DefaultAuthService!

    override func setUp() {
        super.setUp()
        mockAPI = MockRingAPIClient()
        mockKeychain = MockKeychainService()
        sut = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)
    }

    override func tearDown() {
        sut = nil
        mockKeychain = nil
        mockAPI = nil
        super.tearDown()
    }

    // MARK: - Login Success

    func testLoginSuccessReturnsToken() async throws {
        let response = makeValidTokenResponse()
        mockAPI.authenticateResult = .success(response)

        let token = try await sut.login(email: "user@example.com", password: "pass123")

        XCTAssertEqual(token.accessToken, response.accessToken)
        XCTAssertEqual(token.refreshToken, response.refreshToken)
        XCTAssertEqual(token.tokenType, "Bearer")
        XCTAssertFalse(token.isExpired)
    }

    func testLoginSuccessStoresTokenInKeychain() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())

        _ = try await sut.login(email: "user@example.com", password: "pass123")

        XCTAssertEqual(mockKeychain.saveCalls.count, 1)
        XCTAssertEqual(mockKeychain.saveCalls.first?.key, "auth_token")
    }

    func testLoginSuccessCallsAPIWithCorrectCredentials() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())

        _ = try await sut.login(email: "test@ring.com", password: "secret")

        XCTAssertEqual(mockAPI.authenticateCalls.count, 1)
        XCTAssertEqual(mockAPI.authenticateCalls.first?.email, "test@ring.com")
        XCTAssertEqual(mockAPI.authenticateCalls.first?.password, "secret")
    }

    // MARK: - Login Failure

    func testLoginFailurePropagatesInvalidCredentials() async {
        mockAPI.authenticateResult = .failure(RingAPIError.invalidCredentials)

        do {
            _ = try await sut.login(email: "bad@example.com", password: "wrong")
            XCTFail("Expected invalidCredentials error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoginFailureDoesNotStoreToken() async {
        mockAPI.authenticateResult = .failure(RingAPIError.invalidCredentials)

        _ = try? await sut.login(email: "bad@example.com", password: "wrong")

        XCTAssertTrue(mockKeychain.saveCalls.isEmpty)
    }

    func testLoginFailurePropagatesNetworkError() async {
        mockAPI.authenticateResult = .failure(RingAPIError.networkError("offline"))

        do {
            _ = try await sut.login(email: "user@example.com", password: "pass")
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

    // MARK: - Login with 2FA

    func testLoginWith2FASuccess() async throws {
        let response = makeValidTokenResponse()
        mockAPI.authenticateWith2FAResult = .success(response)

        let token = try await sut.login(email: "user@example.com", password: "pass", twoFactorCode: "123456")

        XCTAssertEqual(token.accessToken, response.accessToken)
        XCTAssertEqual(mockAPI.authenticateWith2FACalls.count, 1)
        XCTAssertEqual(mockAPI.authenticateWith2FACalls.first?.code, "123456")
    }

    func testLoginWith2FAFailure() async {
        mockAPI.authenticateWith2FAResult = .failure(RingAPIError.twoFactorInvalid)

        do {
            _ = try await sut.login(email: "user@example.com", password: "pass", twoFactorCode: "000000")
            XCTFail("Expected twoFactorInvalid error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .twoFactorInvalid)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Logout

    func testLogoutClearsInMemoryToken() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        _ = try await sut.login(email: "user@example.com", password: "pass")

        await sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
    }

    func testLogoutDeletesTokenFromKeychain() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        _ = try await sut.login(email: "user@example.com", password: "pass")

        await sut.logout()

        XCTAssertTrue(mockKeychain.deleteCalls.contains("auth_token"))
    }

    func testLogoutWhenNotAuthenticatedDoesNotThrow() async {
        await sut.logout()
        XCTAssertFalse(sut.isAuthenticated)
    }

    // MARK: - getValidToken — Cached Token

    func testGetValidTokenReturnsCachedToken() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        let loginToken = try await sut.login(email: "user@example.com", password: "pass")

        let validToken = try await sut.getValidToken()

        XCTAssertEqual(validToken.accessToken, loginToken.accessToken)
        // Should not have called refresh
        XCTAssertTrue(mockAPI.refreshTokenCalls.isEmpty)
    }

    // MARK: - getValidToken — From Keychain

    func testGetValidTokenLoadsFromKeychainWhenNoCachedToken() async throws {
        let token = makeValidToken()
        try storeTokenInKeychain(token, keychain: mockKeychain)

        // Create a fresh service that has no cached token
        let freshService = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)
        let result = try await freshService.getValidToken()

        XCTAssertEqual(result.accessToken, token.accessToken)
        XCTAssertTrue(mockAPI.refreshTokenCalls.isEmpty)
    }

    // MARK: - getValidToken — Auto-Refresh Expired Token

    func testGetValidTokenAutoRefreshesExpiredToken() async throws {
        // Store an expired token
        let expired = makeExpiredToken()
        try storeTokenInKeychain(expired, keychain: mockKeychain)

        let refreshResponse = makeValidTokenResponse()
        mockAPI.refreshTokenResult = .success(refreshResponse)

        let freshService = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)
        let result = try await freshService.getValidToken()

        XCTAssertEqual(result.accessToken, refreshResponse.accessToken)
        XCTAssertFalse(result.isExpired)
        XCTAssertEqual(mockAPI.refreshTokenCalls.count, 1)
        XCTAssertEqual(mockAPI.refreshTokenCalls.first, expired.refreshToken)
    }

    // MARK: - getValidToken — Auto-Refresh Needs-Refresh Token

    func testGetValidTokenAutoRefreshesNeedsRefreshToken() async throws {
        let needsRefresh = makeNeedsRefreshToken()
        try storeTokenInKeychain(needsRefresh, keychain: mockKeychain)

        let refreshResponse = makeValidTokenResponse()
        mockAPI.refreshTokenResult = .success(refreshResponse)

        let freshService = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)
        let result = try await freshService.getValidToken()

        XCTAssertEqual(result.accessToken, refreshResponse.accessToken)
        XCTAssertFalse(result.isExpired)
        XCTAssertEqual(mockAPI.refreshTokenCalls.count, 1)
    }

    // MARK: - getValidToken — No Token

    func testGetValidTokenThrowsWhenNoTokenExists() async {
        do {
            _ = try await sut.getValidToken()
            XCTFail("Expected tokenExpired error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .tokenExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - getValidToken — Refresh Failure

    func testGetValidTokenThrowsWhenRefreshFails() async throws {
        let expired = makeExpiredToken()
        try storeTokenInKeychain(expired, keychain: mockKeychain)

        mockAPI.refreshTokenResult = .failure(RingAPIError.tokenRefreshFailed)

        let freshService = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)

        do {
            _ = try await freshService.getValidToken()
            XCTFail("Expected tokenRefreshFailed error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .tokenRefreshFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - refreshToken

    func testRefreshTokenStoresNewToken() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        _ = try await sut.login(email: "user@example.com", password: "pass")

        let refreshResponse = makeValidTokenResponse()
        mockAPI.refreshTokenResult = .success(refreshResponse)

        let refreshed = try await sut.refreshToken()

        XCTAssertEqual(refreshed.accessToken, refreshResponse.accessToken)
        XCTAssertFalse(refreshed.isExpired)
        // save called twice: once for login, once for refresh
        XCTAssertEqual(mockKeychain.saveCalls.count, 2)
    }

    func testRefreshTokenThrowsWhenNoExistingToken() async {
        do {
            _ = try await sut.refreshToken()
            XCTFail("Expected tokenRefreshFailed error")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .tokenRefreshFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - isAuthenticated

    func testIsAuthenticatedFalseInitially() {
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testIsAuthenticatedTrueAfterLogin() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        _ = try await sut.login(email: "user@example.com", password: "pass")

        XCTAssertTrue(sut.isAuthenticated)
    }

    func testIsAuthenticatedFalseAfterLogout() async throws {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        _ = try await sut.login(email: "user@example.com", password: "pass")

        await sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
    }

    func testIsAuthenticatedTrueWhenKeychainHasValidToken() throws {
        let token = makeValidToken()
        try storeTokenInKeychain(token, keychain: mockKeychain)

        let freshService = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)
        XCTAssertTrue(freshService.isAuthenticated)
    }

    func testIsAuthenticatedFalseWhenKeychainHasExpiredToken() throws {
        let expired = makeExpiredToken()
        try storeTokenInKeychain(expired, keychain: mockKeychain)

        let freshService = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)
        XCTAssertFalse(freshService.isAuthenticated)
    }

    // MARK: - Keychain Error Handling

    func testLoginThrowsWhenKeychainSaveFails() async {
        mockAPI.authenticateResult = .success(makeValidTokenResponse())
        mockKeychain.saveError = KeychainError.saveFailed(errSecIO)

        do {
            _ = try await sut.login(email: "user@example.com", password: "pass")
            XCTFail("Expected keychain save error")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .saveFailed(errSecIO))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
