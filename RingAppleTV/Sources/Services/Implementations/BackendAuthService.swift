import Foundation
import os

/// Production implementation of `AuthService` that retrieves tokens from the
/// partner auth backend service instead of directly from Ring's OAuth server.
final class BackendAuthService: AuthService, @unchecked Sendable {

    // MARK: - Constants

    /// Keychain key for secure token storage.
    private static let accessTokenKey = "auth_token"

    // MARK: - Dependencies

    private let backendBaseURL: String
    private let apiKey: String
    private let userId: String
    private let keychainService: KeychainService
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.ringappletv", category: "BackendAuthService")

    // MARK: - State

    /// In-memory cached token to avoid repeated keychain reads.
    private var cachedToken: AuthToken?

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

    init(backendBaseURL: String, apiKey: String, userId: String, keychainService: KeychainService, urlSession: URLSession = .shared) {
        self.backendBaseURL = backendBaseURL
        self.apiKey = apiKey
        self.userId = userId
        self.keychainService = keychainService
        self.urlSession = urlSession
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

    func fetchTokenFromBackend() async throws -> AuthToken {
        let urlString = "\(backendBaseURL)/api/token?user_id=\(userId)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid backend URL: \(urlString)")
            throw PartnerAPIError.networkError("Invalid backend URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            logger.error("Network error fetching token from backend: \(error.localizedDescription)")
            throw PartnerAPIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PartnerAPIError.networkError("Invalid response from backend")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            logger.info("Backend returned 401, clearing tokens")
            cachedToken = nil
            try? keychainService.delete(for: Self.accessTokenKey)
            throw PartnerAPIError.unauthorized
        case 404:
            throw PartnerAPIError.notFound
        default:
            throw PartnerAPIError.serverError(httpResponse.statusCode)
        }

        let backendResponse: BackendTokenResponse
        do {
            backendResponse = try JSONDecoder().decode(BackendTokenResponse.self, from: data)
        } catch {
            logger.error("Failed to decode backend token response: \(error.localizedDescription)")
            throw PartnerAPIError.decodingError(error.localizedDescription)
        }

        let token = backendResponse.toDomain()
        try storeToken(token)
        return token
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

        // 3. Token is expired or near-expiry — fetch from backend
        return try await fetchTokenFromBackend()
    }

    func logout() async {
        cachedToken = nil
        try? keychainService.delete(for: Self.accessTokenKey)
    }

    // MARK: - Private Helpers

    /// Store a token in both the in-memory cache and the Keychain.
    private func storeToken(_ token: AuthToken) throws {
        let data = try encoder.encode(token)
        try keychainService.save(data, for: Self.accessTokenKey)
        cachedToken = token
    }

    /// Load a token from the Keychain.
    private func loadTokenFromKeychain() -> AuthToken? {
        guard let data = (try? keychainService.load(for: Self.accessTokenKey)) ?? nil else {
            return nil
        }
        return try? decoder.decode(AuthToken.self, from: data)
    }
}
