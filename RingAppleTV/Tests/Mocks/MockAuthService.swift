import Foundation
@testable import RingAppleTV

/// Mock `AuthService` with configurable return values and call tracking.
final class MockAuthService: AuthService {

    // MARK: - State

    var _isAuthenticated: Bool = false
    var isAuthenticated: Bool { _isAuthenticated }

    // MARK: - login(email:password:)

    var loginResult: Result<AuthToken, Error> = .failure(RingAPIError.invalidCredentials)
    var loginCalls: [(email: String, password: String)] = []

    func login(email: String, password: String) async throws -> AuthToken {
        loginCalls.append((email: email, password: password))
        return try loginResult.get()
    }

    // MARK: - login(email:password:twoFactorCode:)

    var loginWith2FAResult: Result<AuthToken, Error> = .failure(RingAPIError.twoFactorInvalid)
    var loginWith2FACalls: [(email: String, password: String, code: String)] = []

    func login(email: String, password: String, twoFactorCode: String) async throws -> AuthToken {
        loginWith2FACalls.append((email: email, password: password, code: twoFactorCode))
        return try loginWith2FAResult.get()
    }

    // MARK: - logout

    var logoutCalls: Int = 0

    func logout() async {
        logoutCalls += 1
        _isAuthenticated = false
    }

    // MARK: - getValidToken

    var getValidTokenResult: Result<AuthToken, Error> = .failure(RingAPIError.tokenExpired)
    var getValidTokenCalls: Int = 0

    func getValidToken() async throws -> AuthToken {
        getValidTokenCalls += 1
        return try getValidTokenResult.get()
    }

    // MARK: - refreshToken

    var refreshTokenResult: Result<AuthToken, Error> = .failure(RingAPIError.tokenRefreshFailed)
    var refreshTokenCalls: Int = 0

    func refreshToken() async throws -> AuthToken {
        refreshTokenCalls += 1
        return try refreshTokenResult.get()
    }
}
