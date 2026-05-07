import Foundation
import os

/// Production implementation of `PartnerAPIClientProtocol` backed by `URLSession`.
///
/// - Auth endpoints hit `https://oauth.ring.com`
/// - API endpoints hit `https://api.amazonvision.com/v1`
/// - On 429: retries up to 3 times with `Retry-After` or exponential backoff (1s → 2s → 4s)
/// - On 401 (non-auth endpoints): attempts one token refresh before failing
/// - Bearer token injected via `Authorization` header on all API requests
final class PartnerAPIClient: PartnerAPIClientProtocol, @unchecked Sendable {

    // MARK: - Constants

    private let authBaseURL: String
    private let apiBaseURL: String
    private static let maxRetries = 3
    private static let initialBackoff: TimeInterval = 1.0

    /// Build a URL from a hard-coded literal; crash with a clear message if the
    /// literal is malformed (programmer error). Avoids `force_unwrapping` lint
    /// on constants we know statically.
    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("PartnerAPIClient: malformed URL literal \(string)")
        }
        return url
    }

    // MARK: - Dependencies

    private let session: URLSession
    private let logger = Logger(subsystem: "com.ringappletv", category: "PartnerAPIClient")

    /// Optional callback for refreshing the token on 401. Injected by the service layer
    /// after construction to avoid a circular dependency.
    var tokenRefresher: (() async throws -> String)?

    // MARK: - Init

    init(
        session: URLSession = .shared,
        authBaseURL: String = Constants.API.oauthBaseURL,
        apiBaseURL: String = Constants.API.partnerAPIBaseURL
    ) {
        self.session = session
        self.authBaseURL = authBaseURL
        self.apiBaseURL = apiBaseURL
    }

    // MARK: - Auth — Device Code Flow

    func requestDeviceCode(clientId: String) async throws -> DeviceCodeResponse {
        let url = Self.url("\(self.authBaseURL)/oauth/device/code")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["client_id": clientId]
        request.httpBody = formEncode(body)

        log("Requesting device code")
        return try await perform(request, decoding: DeviceCodeResponse.self, isAuthEndpoint: true)
    }

    func pollForToken(clientId: String, clientSecret: String, deviceCode: String) async throws -> AuthToken {
        let url = Self.url("\(self.authBaseURL)/oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": clientId,
            "client_secret": clientSecret
        ]
        request.httpBody = formEncode(body)

        log("Polling for token")
        let raw = try await perform(request, decoding: RawTokenResponse.self, isAuthEndpoint: true)
        return raw.toDomain()
    }

    func refreshToken(clientId: String, clientSecret: String, refreshToken: String) async throws -> AuthToken {
        let url = Self.url("\(self.authBaseURL)/oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "client_secret": clientSecret
        ]
        request.httpBody = formEncode(body)

        log("Refreshing token")
        let raw = try await perform(request, decoding: RawTokenResponse.self, isAuthEndpoint: true)
        return raw.toDomain()
    }

    // MARK: - Devices

    func fetchDevices(token: String) async throws -> [PartnerDeviceResource] {
        let url = Self.url("\(self.apiBaseURL)/devices")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        injectBearer(token, into: &request)

        log("Fetching devices")
        let response = try await perform(request, decoding: PartnerDeviceListResponse.self, token: token)
        return response.data
    }

    // MARK: - Events

    func fetchEvents(deviceId: String, token: String, limit: Int) async throws -> [PartnerEventResource] {
        let componentsString = "\(self.apiBaseURL)/history/devices/\(deviceId)/events"
        guard var components = URLComponents(string: componentsString) else {
            throw PartnerAPIError.decodingError("Invalid URL components for history")
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]

        guard let url = components.url else {
            throw PartnerAPIError.decodingError("Invalid URL components for history")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        injectBearer(token, into: &request)

        log("Fetching events for device \(deviceId), limit \(limit)")
        return try await perform(request, decoding: [PartnerEventResource].self, token: token)
    }

    // MARK: - Media

    func downloadVideo(deviceId: String, eventId: String, token: String) async throws -> URL {
        let url = Self.url("\(self.apiBaseURL)/devices/\(deviceId)/media/video/download")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        injectBearer(token, into: &request)

        let body = ["event_id": eventId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        log("Downloading video for device \(deviceId), event \(eventId)")
        let wrapper = try await perform(request, decoding: VideoDownloadResponse.self, token: token)
        guard let videoURL = URL(string: wrapper.url) else {
            throw PartnerAPIError.decodingError("Invalid video URL in response")
        }
        return videoURL
    }

    func downloadSnapshot(deviceId: String, token: String) async throws -> Data {
        let url = Self.url("\(self.apiBaseURL)/devices/\(deviceId)/media/image/download")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        injectBearer(token, into: &request)

        log("Downloading snapshot for device \(deviceId)")
        return try await performRaw(request, token: token)
    }

    // MARK: - WHEP (Live Streaming)

    func createWHEPSession(deviceId: String, sdpOffer: String, token: String) async throws -> WHEPSessionResponse {
        let url = Self.url("\(self.apiBaseURL)/devices/\(deviceId)/media/streaming/whep/sessions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        injectBearer(token, into: &request)
        request.httpBody = Data(sdpOffer.utf8)

        log("Creating WHEP session for device \(deviceId)")

        let (data, response) = try await executeWithRetry(request, token: token)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PartnerAPIError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 201 else {
            try mapStatusCode(httpResponse.statusCode, data: data)
            // mapStatusCode throws for non-2xx; this line is unreachable but satisfies the compiler
            throw PartnerAPIError.serverError(httpResponse.statusCode)
        }

        guard let sdpAnswer = String(data: data, encoding: .utf8), !sdpAnswer.isEmpty else {
            throw PartnerAPIError.decodingError("Empty SDP answer in WHEP response")
        }

        guard let locationHeader = httpResponse.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: locationHeader) else {
            throw PartnerAPIError.decodingError("Missing or invalid Location header in WHEP response")
        }

        return WHEPSessionResponse(sdpAnswer: sdpAnswer, sessionURL: sessionURL)
    }

    func deleteWHEPSession(sessionURL: URL, token: String) async throws {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "DELETE"
        injectBearer(token, into: &request)

        log("Deleting WHEP session at \(sessionURL.absoluteString)")
        _ = try await performRaw(request, token: token)
    }

    // MARK: - HTTP Error Mapping

    /// Maps HTTP status codes to `PartnerAPIError`. Successful codes (200–299) pass through.
    /// Parses the response body for device-code-flow error codes on auth endpoints.
    func mapStatusCode(_ statusCode: Int, data: Data? = nil) throws {
        switch statusCode {
        case 200...299:
            return
        case 400, 401:
            if let error = deviceCodeError(from: data) {
                throw error
            }
            throw statusCode == 401
                ? PartnerAPIError.unauthorized
                : PartnerAPIError.serverError(statusCode)
        case 403:
            throw PartnerAPIError.forbidden
        case 404:
            throw PartnerAPIError.notFound
        case 429:
            // Actual retry-after is handled in the retry loop.
            throw PartnerAPIError.rateLimited(retryAfter: 0)
        default:
            throw PartnerAPIError.serverError(statusCode)
        }
    }

    /// Maps the JSON `error` field of a device-code-flow response body to the
    /// corresponding typed `PartnerAPIError`, or `nil` if the body does not
    /// contain a recognized code.
    private func deviceCodeError(from data: Data?) -> PartnerAPIError? {
        guard let data = data, let code = parseDeviceCodeError(from: data) else {
            return nil
        }
        switch code {
        case "authorization_pending": return .authorizationPending
        case "slow_down":             return .slowDown
        case "expired_token":         return .expiredDeviceCode
        default:                      return nil
        }
    }

    // MARK: - Private Helpers

    /// Executes a request with JSON decoding. Handles retry on 429 and token refresh on 401.
    private func perform<T: Decodable>(
        _ request: URLRequest,
        decoding type: T.Type,
        isAuthEndpoint: Bool = false,
        token: String? = nil
    ) async throws -> T {
        let (data, response) = try await executeWithRetry(request, isAuthEndpoint: isAuthEndpoint, token: token)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PartnerAPIError.networkError("Invalid response type")
        }

        let statusCode = httpResponse.statusCode
        log("Response status \(statusCode) for \(request.url?.path ?? "unknown")")

        try mapStatusCode(statusCode, data: data)

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            log("Decoding error: \(error.localizedDescription)")
            throw PartnerAPIError.decodingError(error.localizedDescription)
        }
    }

    /// Executes a request and returns raw data. Handles retry on 429 and token refresh on 401.
    private func performRaw(
        _ request: URLRequest,
        isAuthEndpoint: Bool = false,
        token: String? = nil
    ) async throws -> Data {
        let (data, response) = try await executeWithRetry(request, isAuthEndpoint: isAuthEndpoint, token: token)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PartnerAPIError.networkError("Invalid response type")
        }

        let statusCode = httpResponse.statusCode
        log("Response status \(statusCode) for \(request.url?.path ?? "unknown")")

        try mapStatusCode(statusCode, data: data)

        return data
    }

    /// Core execution loop with 429 retry and 401 token refresh.
    private func executeWithRetry(
        _ request: URLRequest,
        isAuthEndpoint: Bool = false,
        token: String? = nil
    ) async throws -> (Data, URLResponse) {
        var currentRequest = request
        var retryCount = 0
        var backoff = Self.initialBackoff
        var hasAttemptedRefresh = false

        while true {
            let data: Data
            let response: URLResponse

            do {
                (data, response) = try await session.data(for: currentRequest)
            } catch {
                let message = (error as? URLError)?.localizedDescription ?? error.localizedDescription
                log("Network error: \(message)")
                throw PartnerAPIError.networkError(message)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PartnerAPIError.networkError("Invalid response type")
            }

            let statusCode = httpResponse.statusCode

            // Handle 429 — Rate Limited
            if statusCode == 429, retryCount < Self.maxRetries {
                retryCount += 1
                let delay: TimeInterval

                if let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                   let retryAfterSeconds = TimeInterval(retryAfterValue) {
                    delay = retryAfterSeconds
                } else {
                    delay = backoff
                    backoff *= 2
                }

                log("Rate limited (429). Retry \(retryCount)/\(Self.maxRetries) after \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            // Handle 401 — Unauthorized (non-auth endpoints only, one refresh attempt)
            if statusCode == 401, !isAuthEndpoint, !hasAttemptedRefresh,
               let refresher = tokenRefresher {
                hasAttemptedRefresh = true
                log("Received 401 on API endpoint. Attempting token refresh.")

                do {
                    let newToken = try await refresher()
                    injectBearer(newToken, into: &currentRequest)
                    log("Token refreshed. Retrying request.")
                    continue
                } catch {
                    log("Token refresh failed: \(error.localizedDescription)")
                    // Fall through to return the 401 response
                }
            }

            return (data, response)
        }
    }

    /// Injects a Bearer token into the `Authorization` header.
    private func injectBearer(_ token: String, into request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// URL-form-encodes a dictionary.
    private func formEncode(_ params: [String: String]) -> Data {
        let encoded = params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    /// Parses the `error` field from a device code flow error response body.
    private func parseDeviceCodeError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorCode = json["error"] as? String else {
            return nil
        }
        return errorCode
    }

    /// Logs a message without including tokens or passwords.
    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}

// MARK: - Internal Response Wrappers

/// Partner API video download response containing the playable URL.
struct VideoDownloadResponse: Codable {
    let url: String
}

/// Internal DTO for decoding OAuth token endpoint responses.
/// Converts to the domain `AuthToken` via `toDomain()`.
private struct RawTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    func toDomain() -> AuthToken {
        AuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scope: scope,
            tokenType: tokenType,
            clientId: nil
        )
    }
}
