import Foundation

/// Manages authentication state, token lifecycle, and credential storage
/// using a backend-mediated token retrieval flow.
protocol AuthService: Sendable {
    /// Fetch a valid token from the partner auth backend.
    func fetchTokenFromBackend() async throws -> AuthToken
    /// Return a non-expired token, refreshing proactively if within 60s of expiry.
    func getValidToken() async throws -> AuthToken
    /// Clear all stored tokens and transition to unauthenticated state.
    func logout() async
    /// Whether a valid (non-expired) token exists in memory or the Keychain.
    var isAuthenticated: Bool { get }
}
