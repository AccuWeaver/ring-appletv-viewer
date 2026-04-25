import Foundation

/// Manages authentication state, token lifecycle, and credential storage.
protocol AuthService {
    /// Authenticate with email and password. Throws `RingAPIError.twoFactorRequired` if 2FA is needed.
    func login(email: String, password: String) async throws -> AuthToken
    /// Authenticate with email, password, and a two-factor verification code.
    func login(email: String, password: String, twoFactorCode: String) async throws -> AuthToken
    /// Clear the current session and remove stored credentials.
    func logout() async
    /// Return a non-expired token, refreshing transparently if needed.
    func getValidToken() async throws -> AuthToken
    /// Force-refresh the current token using the stored refresh token.
    func refreshToken() async throws -> AuthToken
    /// Whether a valid (non-expired) token exists in memory or the Keychain.
    var isAuthenticated: Bool { get }
}
