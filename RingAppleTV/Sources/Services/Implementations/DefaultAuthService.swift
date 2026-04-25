import Foundation

/// Production implementation of `AuthService` that coordinates authentication
/// through the Ring API, persists tokens in the Keychain, and transparently
/// refreshes expired tokens.
final class DefaultAuthService: AuthService {

    // MARK: - Dependencies

    private let apiClient: RingAPIClient
    private let keychainService: KeychainService

    // MARK: - State

    /// In-memory cached token to avoid repeated keychain reads.
    private var cachedToken: AuthToken?

    /// Keychain key used for token storage.
    private static let tokenKey = "auth_token"

    // MARK: - Codecs

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: - Init

    init(apiClient: RingAPIClient, keychainService: KeychainService) {
        self.apiClient = apiClient
        self.keychainService = keychainService
    }

    // MARK: - AuthService

    var isAuthenticated: Bool {
        if let token = cachedToken, !token.isExpired {
            return true
        }
        // Fall back to keychain
        if let token = loadTokenFromKeychain(), !token.isExpired {
            cachedToken = token
            return true
        }
        return false
    }

    func login(email: String, password: String) async throws -> AuthToken {
        let response = try await apiClient.authenticate(email: email, password: password)
        let token = response.toDomain()
        try storeToken(token)
        return token
    }

    func login(email: String, password: String, twoFactorCode: String) async throws -> AuthToken {
        let response = try await apiClient.authenticate(email: email, password: password, twoFactorCode: twoFactorCode)
        let token = response.toDomain()
        try storeToken(token)
        return token
    }

    func logout() async {
        cachedToken = nil
        try? keychainService.delete(for: Self.tokenKey)
    }

    func getValidToken() async throws -> AuthToken {
        // 1. Try in-memory cache
        if let token = cachedToken, !token.isExpired, !token.needsRefresh {
            return token
        }

        // 2. Try keychain
        if let token = loadTokenFromKeychain(), !token.isExpired, !token.needsRefresh {
            cachedToken = token
            return token
        }

        // 3. Try to refresh if we have a token (expired or needs refresh)
        guard cachedToken != nil || loadTokenFromKeychain() != nil else {
            throw RingAPIError.tokenExpired
        }

        return try await refreshToken()
    }

    func refreshToken() async throws -> AuthToken {
        let existingToken = cachedToken ?? loadTokenFromKeychain()
        guard let tokenToRefresh = existingToken else {
            throw RingAPIError.tokenRefreshFailed
        }

        let response = try await apiClient.refreshToken(tokenToRefresh.refreshToken)
        let newToken = response.toDomain()
        try storeToken(newToken)
        return newToken
    }

    // MARK: - Private Helpers

    private func storeToken(_ token: AuthToken) throws {
        let data = try encoder.encode(token)
        try keychainService.save(data, for: Self.tokenKey)
        cachedToken = token
    }

    private func loadTokenFromKeychain() -> AuthToken? {
        guard let data = (try? keychainService.load(for: Self.tokenKey)) ?? nil else {
            return nil
        }
        return try? decoder.decode(AuthToken.self, from: data)
    }
}
