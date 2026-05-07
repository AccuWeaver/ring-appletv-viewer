import Foundation
@testable import RingAppleTV

/// Mock `AuthService` with configurable return values and call tracking.
final class MockAuthService: AuthService, @unchecked Sendable {

    // MARK: - State

    var _isAuthenticated: Bool = false
    var isAuthenticated: Bool { _isAuthenticated }

    // MARK: - startDeviceCodeFlow

    var startDeviceCodeFlowResult: Result<DeviceCodeInfo, Error> = .failure(PartnerAPIError.unauthorized)
    var startDeviceCodeFlowCalls: Int = 0

    func startDeviceCodeFlow() async throws -> DeviceCodeInfo {
        startDeviceCodeFlowCalls += 1
        return try startDeviceCodeFlowResult.get()
    }

    // MARK: - pollForAuthorization

    var pollForAuthorizationResult: Result<AuthToken, Error> = .failure(PartnerAPIError.authorizationPending)
    var pollForAuthorizationCalls: [String] = []

    func pollForAuthorization(deviceCode: String) async throws -> AuthToken {
        pollForAuthorizationCalls.append(deviceCode)
        return try pollForAuthorizationResult.get()
    }

    // MARK: - logout

    var logoutCalls: Int = 0

    func logout() async {
        logoutCalls += 1
        _isAuthenticated = false
    }

    // MARK: - getValidToken

    var getValidTokenResult: Result<AuthToken, Error> = .failure(PartnerAPIError.unauthorized)
    var getValidTokenCalls: Int = 0

    func getValidToken() async throws -> AuthToken {
        getValidTokenCalls += 1
        return try getValidTokenResult.get()
    }

    // MARK: - fetchTokenFromBackend

    var fetchTokenFromBackendResult: Result<AuthToken, Error> = .failure(PartnerAPIError.unauthorized)
    var fetchTokenFromBackendCalls: Int = 0

    func fetchTokenFromBackend() async throws -> AuthToken {
        fetchTokenFromBackendCalls += 1
        return try fetchTokenFromBackendResult.get()
    }
}
