import Foundation
import os

/// Production implementation of `RingAPIClient` backed by `URLSession`.
/// Accepts a `URLSession` in its initialiser for testability.
final class DefaultRingAPIClient: RingAPIClient {

    // MARK: - Constants

    private static let oauthBaseURL = "https://oauth.ring.com"
    private static let apiBaseURL = "https://api.ring.com"

    // MARK: - Dependencies

    private let session: URLSession
    private let logger = Logger(subsystem: "com.ringappletv", category: "APIClient")

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Authentication (email + password)

    func authenticate(email: String, password: String) async throws -> AuthTokenResponse {
        let url = URL(string: "\(Self.oauthBaseURL)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "password",
            "username": email,
            "password": password,
            "client_id": "ring_official_ios",
            "scope": "client"
        ]
        request.httpBody = formEncode(body)

        log("Authenticating user (email provided)")
        return try await perform(request, decoding: AuthTokenResponse.self)
    }

    // MARK: - Authentication (with 2FA)

    func authenticate(email: String, password: String, twoFactorCode: String) async throws -> AuthTokenResponse {
        let url = URL(string: "\(Self.oauthBaseURL)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "2fa-support")
        request.setValue(twoFactorCode, forHTTPHeaderField: "2fa-code")

        let body: [String: String] = [
            "grant_type": "password",
            "username": email,
            "password": password,
            "client_id": "ring_official_ios",
            "scope": "client"
        ]
        request.httpBody = formEncode(body)

        log("Authenticating user with 2FA code")
        return try await perform(request, decoding: AuthTokenResponse.self)
    }

    // MARK: - Token Refresh

    func refreshToken(_ refreshToken: String) async throws -> AuthTokenResponse {
        let url = URL(string: "\(Self.oauthBaseURL)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "ring_official_ios"
        ]
        request.httpBody = formEncode(body)

        log("Refreshing token")
        return try await perform(request, decoding: AuthTokenResponse.self)
    }

    // MARK: - Fetch Devices

    func fetchDevices(token: String) async throws -> [RingDeviceResponse] {
        let url = URL(string: "\(Self.apiBaseURL)/clients_api/ring_devices")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        log("Fetching devices")

        do {
            let wrapper = try await perform(request, decoding: DevicesWrapper.self)
            log("Successfully decoded DevicesWrapper with \(wrapper.allDevices.count) devices")
            return wrapper.allDevices
        } catch {
            log("Failed to decode devices wrapper: \(error)")
            throw error
        }
    }

    // MARK: - Request Live Stream

    func requestLiveStream(deviceId: Int, token: String) async throws -> StreamSessionResponse {
        let url = URL(string: "\(Self.apiBaseURL)/clients_api/doorbots/\(deviceId)/live_view")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        log("Requesting live stream for device \(deviceId)")
        return try await perform(request, decoding: StreamSessionResponse.self)
    }

    // MARK: - Fetch Events

    func fetchEvents(deviceId: Int, token: String, limit: Int) async throws -> [RingEventResponse] {
        var components = URLComponents(string: "\(Self.apiBaseURL)/clients_api/doorbots/\(deviceId)/history")!
        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        log("Fetching events for device \(deviceId), limit \(limit)")
        return try await perform(request, decoding: [RingEventResponse].self)
    }

    // MARK: - Fetch Event Video URL

    func fetchEventVideoURL(eventId: Int, token: String) async throws -> URL {
        let url = URL(string: "\(Self.apiBaseURL)/clients_api/dings/\(eventId)/share/play")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        log("Fetching video URL for event \(eventId)")

        let wrapper = try await perform(request, decoding: VideoURLWrapper.self)
        guard let videoURL = URL(string: wrapper.url) else {
            throw RingAPIError.decodingError("Invalid video URL in response")
        }
        return videoURL
    }

    // MARK: - Fetch Snapshot

    func fetchSnapshot(deviceId: Int, token: String) async throws -> Data {
        let url = URL(string: "\(Self.apiBaseURL)/clients_api/snapshots/image/\(deviceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        log("Fetching snapshot for device \(deviceId)")
        return try await performRaw(request)
    }

    // MARK: - Request Snapshot

    func requestSnapshot(deviceId: Int, token: String) async throws {
        let url = URL(string: "\(Self.apiBaseURL)/clients_api/doorbots/\(deviceId)/snapshot")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        log("Requesting new snapshot for device \(deviceId)")
        _ = try await performRaw(request)
    }


    // MARK: - Private Helpers

    /// Executes a request, maps HTTP errors to `RingAPIError`, and decodes the response.
    private func perform<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let message = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            log("Network error: \(message)")
            throw RingAPIError.networkError(message)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RingAPIError.unknown("Invalid response type")
        }

        let statusCode = httpResponse.statusCode
        log("Response status \(statusCode) for \(request.url?.path ?? "unknown")")
        
        // Debug: Log response body for non-success codes
        if statusCode < 200 || statusCode >= 300 {
            if let bodyString = String(data: data, encoding: .utf8) {
                log("Response body: \(bodyString)")
            }
        }

        try mapStatusCode(statusCode, data: data)

        do {
            let decoder = JSONDecoder()
            let result = try decoder.decode(T.self, from: data)
            log("Successfully decoded response of type \(T.self)")
            return result
        } catch {
            log("Decoding error: \(error.localizedDescription)")
            if let bodyString = String(data: data, encoding: .utf8) {
                log("Failed to decode response body: \(bodyString)")
            }
            throw RingAPIError.decodingError(error.localizedDescription)
        }
    }

    /// Executes a request, maps HTTP errors to `RingAPIError`, and returns raw response data (not JSON-decoded).
    private func performRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let message = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            log("Network error: \(message)")
            throw RingAPIError.networkError(message)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RingAPIError.unknown("Invalid response type")
        }

        let statusCode = httpResponse.statusCode
        log("Response status \(statusCode) for \(request.url?.path ?? "unknown")")

        if statusCode < 200 || statusCode >= 300 {
            if let bodyString = String(data: data, encoding: .utf8) {
                log("Response body: \(bodyString)")
            }
        }

        try mapStatusCode(statusCode, data: data)

        return data
    }

    /// Maps HTTP status codes to `RingAPIError`. Successful codes (200-299) pass through.
    private func mapStatusCode(_ statusCode: Int, data: Data? = nil) throws {
        switch statusCode {
        case 200...299:
            return
        case 400:
            throw RingAPIError.twoFactorInvalid
        case 401:
            throw RingAPIError.invalidCredentials
        case 404:
            throw RingAPIError.noSnapshotAvailable
        case 412:
            let method = parseTwoFactorMethod(from: data)
            throw RingAPIError.twoFactorRequired(method: method)
        case 429:
            throw RingAPIError.rateLimited
        case 500...599:
            throw RingAPIError.serverError(statusCode)
        default:
            throw RingAPIError.unknown("HTTP \(statusCode)")
        }
    }

    /// Parses the 2FA method from a 412 response body.
    /// Ring returns `"tsv_state"` indicating the method: `"sms"`, `"totp"`, or `"email"`.
    private func parseTwoFactorMethod(from data: Data?) -> TwoFactorMethod {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tsvState = json["tsv_state"] as? String else {
            return .unknown
        }
        switch tsvState.lowercased() {
        case "totp":
            return .authenticator
        case "sms":
            return .sms
        case "email":
            return .email
        default:
            return .unknown
        }
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

    /// Logs a message without including tokens or passwords.
    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}

// MARK: - Internal Response Wrappers

/// Ring's `/clients_api/ring_devices` returns devices grouped by type.
struct DevicesWrapper: Decodable {
    let doorbots: [RingDeviceResponse]?
    let authorizedDoorbots: [RingDeviceResponse]?
    let stickupCams: [RingDeviceResponse]?
    let allCameras: [RingDeviceResponse]?

    enum CodingKeys: String, CodingKey {
        case doorbots
        case authorizedDoorbots = "authorized_doorbots"
        case stickupCams = "stickup_cams"
        case allCameras = "all_cameras"
    }

    var allDevices: [RingDeviceResponse] {
        var devices: [RingDeviceResponse] = []
        if let d = doorbots { devices.append(contentsOf: d) }
        if let d = authorizedDoorbots { devices.append(contentsOf: d) }
        if let d = stickupCams { devices.append(contentsOf: d) }
        if let d = allCameras { devices.append(contentsOf: d) }
        return devices
    }
}

/// Ring's event video URL response.
struct VideoURLWrapper: Decodable {
    let url: String
}
