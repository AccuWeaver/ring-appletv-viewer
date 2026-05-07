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
            tokenType: "Bearer",
            clientId: nil
        )
    }

    // MARK: - checkBackendForToken Success

    func testCheckBackendForTokenSuccess_transitionsToLoaded() async {
        let (sut, mock) = makeSUT()
        let token = makeToken()
        mock.fetchTokenFromBackendResult = .success(token)

        await sut.checkBackendForToken()

        guard case .loaded(let loadedToken) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedToken, token)
        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertEqual(mock.fetchTokenFromBackendCalls, 1)
    }

    func testCheckBackendForTokenSuccess_hidesSetupInstructions() async {
        let (sut, mock) = makeSUT()
        mock.fetchTokenFromBackendResult = .success(makeToken())
        sut.showSetupInstructions()
        XCTAssertTrue(sut.setupInstructionsVisible)

        await sut.checkBackendForToken()

        XCTAssertFalse(sut.setupInstructionsVisible)
    }

    // MARK: - checkBackendForToken Failure

    func testCheckBackendForTokenFailure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.fetchTokenFromBackendResult = .failure(PartnerAPIError.unauthorized)

        await sut.checkBackendForToken()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, PartnerAPIError.unauthorized.userMessage)
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testCheckBackendForTokenNetworkError_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.fetchTokenFromBackendResult = .failure(PartnerAPIError.networkError("timeout"))

        await sut.checkBackendForToken()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, PartnerAPIError.networkError("timeout").userMessage)
    }

    func testCheckBackendForTokenWithGenericError_usesLocalizedDescription() async {
        let (sut, mock) = makeSUT()
        let genericError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        mock.fetchTokenFromBackendResult = .failure(genericError)

        await sut.checkBackendForToken()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "Something broke")
    }

    // MARK: - Logout

    func testLogout_resetsAllState() async {
        let (sut, mock) = makeSUT()
        mock.fetchTokenFromBackendResult = .success(makeToken())

        await sut.checkBackendForToken()
        XCTAssertTrue(sut.isAuthenticated)

        await sut.logout()

        guard case .idle = sut.state else {
            XCTFail("Expected .idle state after logout, got \(sut.state)")
            return
        }
        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertFalse(sut.setupInstructionsVisible)
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
        mock.getValidTokenResult = .failure(PartnerAPIError.unauthorized)

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
        mock.fetchTokenFromBackendResult = .failure(PartnerAPIError.unauthorized)
        await sut.checkBackendForToken()
        XCTAssertFalse(sut.isAuthenticated)
    }

    // MARK: - showSetupInstructions

    func testShowSetupInstructions_setsVisibleFlag() {
        let (sut, _) = makeSUT()
        XCTAssertFalse(sut.setupInstructionsVisible)

        sut.showSetupInstructions()

        XCTAssertTrue(sut.setupInstructionsVisible)
    }
}
