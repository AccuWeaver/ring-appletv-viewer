import Foundation

/// Mock auth service for local development.
/// Always returns a valid dummy token so the app can exercise the full UI
/// flow against the local mock backend without real Ring credentials.
final class MockAuthService: AuthService, @unchecked Sendable {

    private let dummyToken = AuthToken(
        accessToken: "mock_access_token",
        refreshToken: "mock_refresh_token",
        expiresAt: Date().addingTimeInterval(3600),
        scope: "read",
        tokenType: "Bearer",
        clientId: nil
    )

    var isAuthenticated: Bool { true }

    func fetchTokenFromBackend() async throws -> AuthToken {
        dummyToken
    }

    func getValidToken() async throws -> AuthToken {
        dummyToken
    }

    func logout() async {
        // No-op in mock mode
    }
}
