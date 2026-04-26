import XCTest
@testable import RingAppleTV

@MainActor
final class AuthViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(authService: MockAuthService = MockAuthService()) -> (AuthViewModel, MockAuthService) {
        let vm = AuthViewModel(authService: authService)
        return (vm, authService)
    }

    private func makeToken(expired: Bool = false) -> AuthToken {
        AuthToken(
            accessToken: "access-123",
            refreshToken: "refresh-456",
            expiresAt: expired ? Date().addingTimeInterval(-60) : Date().addingTimeInterval(3600),
            scope: "client",
            tokenType: "Bearer"
        )
    }

    // MARK: - Login Success

    func testLoginSuccess_transitionsToLoaded() async {
        let (sut, mock) = makeSUT()
        let token = makeToken()
        mock.loginResult = .success(token)

        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        guard case .loaded(let loadedToken) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedToken, token)
        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertEqual(mock.loginCalls.count, 1)
        XCTAssertEqual(mock.loginCalls.first?.email, "user@example.com")
    }

    // MARK: - Login Failure

    func testLoginFailure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.loginResult = .failure(RingAPIError.invalidCredentials)

        sut.email = "bad@example.com"
        sut.password = "wrong"

        await sut.login()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.invalidCredentials.userMessage)
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testLoginNetworkError_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.loginResult = .failure(RingAPIError.networkError("timeout"))

        await sut.login()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.networkError("timeout").userMessage)
    }

    // MARK: - Two-Factor Authentication

    func testTwoFactorRequired_setsRequiresTwoFactor() async {
        let (sut, mock) = makeSUT()
        mock.loginResult = .failure(RingAPIError.twoFactorRequired(method: .authenticator))

        await sut.login()

        XCTAssertTrue(sut.requiresTwoFactor)
        // State should go back to idle so the user can enter the code
        guard case .idle = sut.state else {
            XCTFail("Expected .idle state after 2FA required, got \(sut.state)")
            return
        }
    }

    func testTwoFactorLogin_usesCodeAndSucceeds() async {
        let (sut, mock) = makeSUT()
        let token = makeToken()
        mock.loginWith2FAResult = .success(token)

        sut.email = "user@example.com"
        sut.password = "password123"
        sut.requiresTwoFactor = true
        sut.twoFactorCode = "123456"

        await sut.login()

        guard case .loaded(let loadedToken) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedToken, token)
        XCTAssertFalse(sut.requiresTwoFactor)
        XCTAssertEqual(sut.twoFactorCode, "")
        XCTAssertEqual(mock.loginWith2FACalls.count, 1)
        XCTAssertEqual(mock.loginWith2FACalls.first?.code, "123456")
    }

    func testTwoFactorInvalid_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.loginWith2FAResult = .failure(RingAPIError.twoFactorInvalid)

        sut.requiresTwoFactor = true
        sut.twoFactorCode = "000000"

        await sut.login()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.twoFactorInvalid.userMessage)
    }

    // MARK: - Logout

    func testLogout_resetsAllState() async {
        let (sut, mock) = makeSUT()
        let token = makeToken()
        mock.loginResult = .success(token)

        sut.email = "user@example.com"
        sut.password = "password123"
        await sut.login()
        XCTAssertTrue(sut.isAuthenticated)

        await sut.logout()

        guard case .idle = sut.state else {
            XCTFail("Expected .idle state after logout, got \(sut.state)")
            return
        }
        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.email, "")
        XCTAssertEqual(sut.password, "")
        XCTAssertEqual(sut.twoFactorCode, "")
        XCTAssertFalse(sut.requiresTwoFactor)
        XCTAssertEqual(mock.logoutCalls, 1)
    }

    // MARK: - Check Existing Auth

    func testCheckExistingAuth_whenAuthenticated_transitionsToLoaded() async {
        let mock = MockAuthService()
        mock._isAuthenticated = true
        let token = makeToken()
        mock.getValidTokenResult = .success(token)

        let (sut, _) = makeSUT(authService: mock)

        await sut.checkExistingAuth()

        guard case .loaded(let loadedToken) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedToken, token)
    }

    func testCheckExistingAuth_whenNotAuthenticated_staysIdle() async {
        let mock = MockAuthService()
        mock._isAuthenticated = false

        let (sut, _) = makeSUT(authService: mock)

        await sut.checkExistingAuth()

        guard case .idle = sut.state else {
            XCTFail("Expected .idle state, got \(sut.state)")
            return
        }
    }

    func testCheckExistingAuth_whenTokenFails_transitionsToIdle() async {
        let mock = MockAuthService()
        mock._isAuthenticated = true
        mock.getValidTokenResult = .failure(RingAPIError.tokenExpired)

        let (sut, _) = makeSUT(authService: mock)

        await sut.checkExistingAuth()

        guard case .idle = sut.state else {
            XCTFail("Expected .idle state after token failure, got \(sut.state)")
            return
        }
    }

    // MARK: - isAuthenticated

    func testIsAuthenticated_falseWhenIdle() {
        let (sut, _) = makeSUT()
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testIsAuthenticated_falseWhenError() async {
        let (sut, mock) = makeSUT()
        mock.loginResult = .failure(RingAPIError.invalidCredentials)
        await sut.login()
        XCTAssertFalse(sut.isAuthenticated)
    }

    // MARK: - Non-RingAPIError

    func testLoginWithGenericError_usesLocalizedDescription() async {
        let (sut, mock) = makeSUT()
        let genericError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        mock.loginResult = .failure(genericError)

        await sut.login()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "Something broke")
    }
}
