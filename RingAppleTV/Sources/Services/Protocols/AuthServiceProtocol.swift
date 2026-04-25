import Foundation

/// Manages authentication state, token lifecycle, and credential storage.
protocol AuthService {
    func login(email: String, password: String) async throws -> AuthToken
    func login(email: String, password: String, twoFactorCode: String) async throws -> AuthToken
    func logout() async
    func getValidToken() async throws -> AuthToken
    func refreshToken() async throws -> AuthToken
    var isAuthenticated: Bool { get }
}
