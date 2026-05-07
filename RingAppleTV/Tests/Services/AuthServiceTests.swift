import XCTest
@testable import RingAppleTV

// MARK: - Test Helpers

private func makeValidTokenResponse(expiresIn: TimeInterval = 3600) -> AuthToken {
    AuthToken(
        accessToken: "access_\(UUID().uuidString)",
        refreshToken: "refresh_\(UUID().uuidString)",
        expiresAt: Date().addingTimeInterval(expiresIn),
        scope: "client",
        tokenType: "Bearer",
        clientId: nil
    )
}

private func makeExpiredToken() -> AuthToken {
    AuthToken(
        accessToken: "expired_access",
        refreshToken: "expired_refresh",
        expiresAt: Date().addingTimeInterval(-60),
        scope: "client",
        tokenType: "Bearer",
        clientId: nil
    )
}

private func makeValidToken(expiresIn: TimeInterval = 3600) -> AuthToken {
    AuthToken(
        accessToken: "valid_access",
        refreshToken: "valid_refresh",
        expiresAt: Date().addingTimeInterval(expiresIn),
        scope: "client",
        tokenType: "Bearer",
        clientId: nil
    )
}

private func makeNeedsRefreshToken() -> AuthToken {
    // Expires in 30 seconds — within the 60-second refresh window
    AuthToken(
        accessToken: "soon_access",
        refreshToken: "soon_refresh",
        expiresAt: Date().addingTimeInterval(30),
        scope: "client",
        tokenType: "Bearer",
        clientId: nil
    )
}

private func makeDeviceCodeResponse() -> DeviceCodeResponse {
    DeviceCodeResponse(
        deviceCode: "test_device_code",
        userCode: "ABCD-1234",
        verificationUri: "https://oauth.ring.com/activate",
        verificationUriComplete: "https://oauth.ring.com/activate?user_code=ABCD-1234",
        expiresIn: 1800,
        interval: 5
    )
}

/// Stores a token in the mock keychain using the same encoding DefaultAuthService uses.
private func storeTokenInKeychain(_ token: AuthToken, keychain: MockKeychainService) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(token)
    try keychain.save(data, for: "auth_token")
}

/// Stores a client secret in the mock keychain.
private func storeClientSecret(_ secret: String, keychain: MockKeychainService) throws {
    let data = Data(secret.utf8)
    try keychain.save(data, for: "client_secret")
}

// MARK: - AuthServiceTests

final class AuthServiceTests: XCTestCase {

    private var mockAPI: MockPartnerAPIClient!
    private var mockKeychain: MockKeychainService!
    private var sut: DefaultAuthService!

    override func setUp() {
        super.setUp()
        mockAPI = MockPartnerAPIClient()
        mockKeychain = MockKeychainService()
        sut = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)
    }

    override func tearDown() {
        sut = nil
        mockKeychain = nil
        mockAPI = nil
        super.tearDown()
    }

    // MARK: - startDeviceCodeFlow

    func testStartDeviceCodeFlowReturnsDeviceCodeInfo() async throws {
        let response = makeDeviceCodeResponse()
        mockAPI.requestDeviceCodeResult = .success(response)

        let info = try await sut.startDeviceCodeFlow()

        XCTAssertEqual(info.userCode, "ABCD-1234")
        XCTAssertEqual(info.verificationUri, "https://oauth.ring.com/activate")
        XCTAssertEqual(info.deviceCode, "test_device_code")
        XCTAssertEqual(info.pollingInterval, 5)
        XCTAssertEqual(info.expiresIn, 1800)
    }

    func testStartDeviceCodeFlowCallsAPIWithClientId() async throws {
        mockAPI.requestDeviceCodeResult = .success(makeDeviceCodeResponse())

        _ = try await sut.startDeviceCodeFlow()

        XCTAssertEqual(mockAPI.requestDeviceCodeCalls.count, 1)
    }

    // MARK: - pollForAuthorization — Success

    func testPollForAuthorizationReturnsTokenOnSuccess() async throws {
        let tokenResponse = makeValidTokenResponse()
        mockAPI.pollForTokenResult = .success(tokenResponse)

        let token = try await sut.pollForAuthorization(deviceCode: "test_device_code")

        XCTAssertEqual(token.accessToken, tokenResponse.accessToken)
        XCTAssertEqual(token.refreshToken, tokenResponse.refreshToken)
        XCTAssertFalse(token.isExpired)
    }

    func testPollForAuthorizationStoresTokenInKeychain() async throws {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())

        _ = try await sut.pollForAuthorization(deviceCode: "test_device_code")

        // save called for the token
        let tokenSaves = mockKeychain.saveCalls.filter { $0.key == "auth_token" }
        XCTAssertEqual(tokenSaves.count, 1)
    }

    // MARK: - pollForAuthorization — Expired Device Code

    func testPollForAuthorizationThrowsOnExpiredDeviceCode() async {
        mockAPI.pollForTokenResult = .failure(PartnerAPIError.expiredDeviceCode)

        do {
            _ = try await sut.pollForAuthorization(deviceCode: "expired_code")
            XCTFail("Expected expiredDeviceCode error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .expiredDeviceCode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Logout

    func testLogoutClearsInMemoryToken() async throws {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())
        _ = try await sut.pollForAuthorization(deviceCode: "test")

        await sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
    }

    func testLogoutDeletesTokenFromKeychain() async throws {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())
        _ = try await sut.pollForAuthorization(deviceCode: "test")

        await sut.logout()

        XCTAssertTrue(mockKeychain.deleteCalls.contains("auth_token"))
    }

    func testLogoutWhenNotAuthenticatedDoesNotThrow() async {
        await sut.logout()
        XCTAssertFalse(sut.isAuthenticated)
    }

    // MARK: - getValidToken — Cached Token

    func testGetValidTokenReturnsCachedToken() async throws {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())
        let authToken = try await sut.pollForAuthorization(deviceCode: "test")

        let validToken = try await sut.getValidToken()

        XCTAssertEqual(validToken.accessToken, authToken.accessToken)
        // Should not have called refresh
        XCTAssertTrue(mockAPI.refreshTokenCalls.isEmpty)
    }

    // MARK: - getValidToken — From Keychain

    func testGetValidTokenLoadsFromKeychainWhenNoCachedToken() async throws {
        let token = makeValidToken()
        try storeTokenInKeychain(token, keychain: mockKeychain)

        let freshService = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)
        let result = try await freshService.getValidToken()

        XCTAssertEqual(result.accessToken, token.accessToken)
        XCTAssertTrue(mockAPI.refreshTokenCalls.isEmpty)
    }

    // MARK: - getValidToken — Auto-Refresh Expired Token

    func testGetValidTokenAutoRefreshesExpiredToken() async throws {
        let expired = makeExpiredToken()
        try storeTokenInKeychain(expired, keychain: mockKeychain)

        let refreshResponse = makeValidTokenResponse()
        mockAPI.refreshTokenResult = .success(refreshResponse)

        let freshService = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)
        let result = try await freshService.getValidToken()

        XCTAssertEqual(result.accessToken, refreshResponse.accessToken)
        XCTAssertFalse(result.isExpired)
        XCTAssertEqual(mockAPI.refreshTokenCalls.count, 1)
    }

    // MARK: - getValidToken — Auto-Refresh Needs-Refresh Token

    func testGetValidTokenAutoRefreshesNeedsRefreshToken() async throws {
        let needsRefresh = makeNeedsRefreshToken()
        try storeTokenInKeychain(needsRefresh, keychain: mockKeychain)

        let refreshResponse = makeValidTokenResponse()
        mockAPI.refreshTokenResult = .success(refreshResponse)

        let freshService = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)
        let result = try await freshService.getValidToken()

        XCTAssertEqual(result.accessToken, refreshResponse.accessToken)
        XCTAssertFalse(result.isExpired)
        XCTAssertEqual(mockAPI.refreshTokenCalls.count, 1)
    }

    // MARK: - getValidToken — No Token

    func testGetValidTokenThrowsWhenNoTokenExists() async {
        do {
            _ = try await sut.getValidToken()
            XCTFail("Expected unauthorized error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - getValidToken — Refresh Failure (401 clears tokens)

    func testGetValidTokenClearsTokensOnRefresh401() async throws {
        let expired = makeExpiredToken()
        try storeTokenInKeychain(expired, keychain: mockKeychain)

        mockAPI.refreshTokenResult = .failure(PartnerAPIError.unauthorized)

        let freshService = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)

        do {
            _ = try await freshService.getValidToken()
            XCTFail("Expected unauthorized error")
        } catch let error as PartnerAPIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Tokens should be cleared
        XCTAssertFalse(freshService.isAuthenticated)
        XCTAssertTrue(mockKeychain.deleteCalls.contains("auth_token"))
    }

    // MARK: - isAuthenticated

    func testIsAuthenticatedFalseInitially() {
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testIsAuthenticatedTrueAfterPollSuccess() async throws {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())
        _ = try await sut.pollForAuthorization(deviceCode: "test")

        XCTAssertTrue(sut.isAuthenticated)
    }

    func testIsAuthenticatedFalseAfterLogout() async throws {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())
        _ = try await sut.pollForAuthorization(deviceCode: "test")

        await sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
    }

    func testIsAuthenticatedTrueWhenKeychainHasValidToken() throws {
        let token = makeValidToken()
        try storeTokenInKeychain(token, keychain: mockKeychain)

        let freshService = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)
        XCTAssertTrue(freshService.isAuthenticated)
    }

    func testIsAuthenticatedFalseWhenKeychainHasExpiredToken() throws {
        let expired = makeExpiredToken()
        try storeTokenInKeychain(expired, keychain: mockKeychain)

        let freshService = DefaultAuthService(partnerAPIClient: mockAPI, keychainService: mockKeychain)
        XCTAssertFalse(freshService.isAuthenticated)
    }

    // MARK: - Keychain Error Handling

    func testPollThrowsWhenKeychainSaveFails() async {
        mockAPI.pollForTokenResult = .success(makeValidTokenResponse())
        mockKeychain.saveError = KeychainError.saveFailed(errSecIO)

        do {
            _ = try await sut.pollForAuthorization(deviceCode: "test")
            XCTFail("Expected keychain save error")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .saveFailed(errSecIO))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
