import Foundation

/// Thin networking layer that communicates with Ring's private API.
/// All methods are async and throw `RingAPIError` on failure.
protocol RingAPIClient {
    /// Authenticate with email/password grant. Returns raw token response.
    func authenticate(email: String, password: String) async throws -> AuthTokenResponse
    /// Authenticate with email/password and a 2FA verification code.
    func authenticate(email: String, password: String, twoFactorCode: String) async throws -> AuthTokenResponse
    /// Exchange a refresh token for a new access token.
    func refreshToken(_ refreshToken: String) async throws -> AuthTokenResponse
    /// Fetch all Ring devices associated with the account.
    func fetchDevices(token: String) async throws -> [RingDeviceResponse]
    /// Request an HLS live stream URL for a specific device.
    func requestLiveStream(deviceId: Int, token: String) async throws -> StreamSessionResponse
    /// Fetch event history for a device, limited to `limit` results.
    func fetchEvents(deviceId: Int, token: String, limit: Int) async throws -> [RingEventResponse]
    /// Retrieve the playback URL for a specific recorded event.
    func fetchEventVideoURL(eventId: Int, token: String) async throws -> URL
}
