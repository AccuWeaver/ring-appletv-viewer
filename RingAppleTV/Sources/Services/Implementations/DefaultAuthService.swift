import Foundation
import os

/// Production implementation of `AuthService` that coordinates authentication
/// through the Ring Partner API using the OAuth 2.0 Device Authorization Grant (RFC 8628),
/// persists tokens in the Keychain, and transparently refreshes expired tokens.
final class DefaultAuthService: AuthService, @unchecked Sendable {

    // MARK: - Constants

    /// Ring Partner API client ID.
    private static let clientId = "ringappletvviewer_aLSt3GfkNqOTRg3MAK5xw"

    /// Keychain keys for secure storage.
    private static let accessTokenKey = "auth_token"
    private static let clientSecretKey = "client_secret"

    // MARK: - Dependencies

    private let partnerAPIClient: PartnerAPIClientProtocol
    private let keychainService: KeychainService
    private let logger = Logger(subsystem: "com.ringappletv", category: "AuthService")

    // MARK: - State

    /// In-memory cached token to avoid repeated keychain reads.
    private var cachedToken: AuthToken?

    // MARK: - Codecs

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    // MARK: - Init

    init(partnerAPIClient: PartnerAPIClientProtocol, keychainService: KeychainService) {
        self.partnerAPIClient = partnerAPIClient
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

    func fetchTokenFromBackend() async throws -> AuthToken {
        // DefaultAuthService does not support backend token retrieval.
        // Use BackendAuthService instead.
        throw PartnerAPIError.unauthorized
    }

    func startDeviceCodeFlow() async throws -> DeviceCodeInfo {
        let response = try await partnerAPIClient.requestDeviceCode(clientId: Self.clientId)
        return DeviceCodeInfo(
            userCode: response.userCode,
            verificationUri: response.verificationUri,
            verificationUriComplete: response.verificationUriComplete,
            expiresIn: TimeInterval(response.expiresIn),
            pollingInterval: TimeInterval(response.interval),
            deviceCode: response.deviceCode
        )
    }

    func pollForAuthorization(deviceCode: String) async throws -> AuthToken {
        let clientSecret = try loadClientSecret()
        var currentInterval: TimeInterval = 5 // Default polling interval per RFC 8628

        while true {
            do {
                let response = try await partnerAPIClient.pollForToken(
                    clientId: Self.clientId,
                    clientSecret: clientSecret,
                    deviceCode: deviceCode
                )
                try storeToken(response)
                return response
            } catch let error as PartnerAPIError {
                switch error {
                case .authorizationPending:
                    // User hasn't authorized yet — wait and retry at current interval
                    logger.debug("Authorization pending, polling again in \(currentInterval)s")
                    try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
                    continue
                case .slowDown:
                    // Increase polling interval by 5 seconds per RFC 8628
                    currentInterval += 5
                    logger.debug("Slow down received, increasing interval to \(currentInterval)s")
                    try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
                    continue
                case .expiredDeviceCode:
                    // Device code expired — propagate error so UI can prompt restart
                    logger.info("Device code expired, user must restart linking")
                    throw error
                default:
                    throw error
                }
            }
        }
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
        let existingToken = cachedToken ?? loadTokenFromKeychain()
        guard let tokenToRefresh = existingToken else {
            throw PartnerAPIError.unauthorized
        }

        return try await refreshToken(using: tokenToRefresh)
    }

    func logout() async {
        cachedToken = nil
        try? keychainService.delete(for: Self.accessTokenKey)
    }

    // MARK: - Private Helpers

    /// Refresh the access token using the stored refresh token.
    /// On 401 failure: clears all tokens and transitions to unauthenticated.
    private func refreshToken(using token: AuthToken) async throws -> AuthToken {
        let clientSecret = try loadClientSecret()

        do {
            let response = try await partnerAPIClient.refreshToken(
                clientId: Self.clientId,
                clientSecret: clientSecret,
                refreshToken: token.refreshToken
            )
            try storeToken(response)
            return response
        } catch let error as PartnerAPIError where error == .unauthorized {
            // Refresh returned 401 — clear all tokens, transition to unauthenticated
            logger.info("Token refresh returned 401, clearing all tokens")
            cachedToken = nil
            try? keychainService.delete(for: Self.accessTokenKey)
            throw PartnerAPIError.unauthorized
        }
    }

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

    /// Load the client secret from the Keychain.
    /// The client_secret must be provisioned in the Keychain at app install or first launch —
    /// it is never stored in plaintext source code.
    private func loadClientSecret() throws -> String {
        // 1. Try Keychain first
        if let data = try keychainService.load(for: Self.clientSecretKey),
           let secret = String(data: data, encoding: .utf8), !secret.isEmpty {
            return secret
        }

        // 2. Try loading from bundled credentials CSV (development only)
        if let secret = loadClientSecretFromCSV() {
            logger.info("Provisioned client secret from credentials CSV into Keychain")
            if let data = secret.data(using: .utf8) {
                try? keychainService.save(data, for: Self.clientSecretKey)
            }
            return secret
        }

        logger.error("Client secret not found in Keychain or credentials file")
        throw PartnerAPIError.unauthorized
    }

    /// Attempt to load the client secret from a bundled `app-credentials.csv` file.
    /// Format: two rows — "Client ID,<value>" and "Client Secret,<value>".
    private func loadClientSecretFromCSV() -> String? {
        // Check the app bundle first, then fall back to the source directory (simulator)
        let bundlePath = Bundle.main.path(forResource: "app-credentials", ofType: "csv")
        guard let path = bundlePath else {
            logger.debug("No app-credentials.csv found in bundle")
            return nil
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.components(separatedBy: ",")
            if parts.count >= 2 && parts[0].trimmingCharacters(in: .whitespaces) == "Client Secret" {
                let secret = parts[1].trimmingCharacters(in: .whitespaces)
                return secret.isEmpty ? nil : secret
            }
        }
        return nil
    }
}
