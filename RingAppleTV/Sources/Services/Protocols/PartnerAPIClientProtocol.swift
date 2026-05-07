import Foundation

/// Networking layer for all Ring Partner API communication, including WHEP session management.
///
/// All methods are `async throws`. Auth endpoints (device code, token polling, refresh)
/// do not require a Bearer token; all other endpoints do.
protocol PartnerAPIClientProtocol: Sendable {

    // MARK: - Auth — Device Code Flow

    /// Request a device code and user code from the authorization server (RFC 8628).
    func requestDeviceCode(clientId: String) async throws -> DeviceCodeResponse

    /// Poll the token endpoint with the device code. Returns an `AuthToken` on success,
    /// or throws `PartnerAPIError.authorizationPending`, `.slowDown`, or `.expiredDeviceCode`.
    func pollForToken(clientId: String, clientSecret: String, deviceCode: String) async throws -> AuthToken

    /// Exchange a refresh token for a new access/refresh token pair.
    func refreshToken(clientId: String, clientSecret: String, refreshToken: String) async throws -> AuthToken

    // MARK: - Devices

    /// Fetch all devices associated with the account.
    func fetchDevices(token: String) async throws -> [PartnerDeviceResource]

    // MARK: - Events

    /// Fetch event history for a device, limited to `limit` results.
    func fetchEvents(deviceId: String, token: String, limit: Int) async throws -> [PartnerEventResource]

    // MARK: - Media

    /// Download a video clip for a specific event. Returns the playable video URL.
    func downloadVideo(deviceId: String, eventId: String, token: String) async throws -> URL

    /// Download the latest cached snapshot image for a device. Returns raw image data.
    func downloadSnapshot(deviceId: String, token: String) async throws -> Data

    // MARK: - WHEP (Live Streaming)

    /// Create a WHEP session by POSTing an SDP offer. Returns the SDP answer and session URL.
    func createWHEPSession(deviceId: String, sdpOffer: String, token: String) async throws -> WHEPSessionResponse

    /// Delete a WHEP session (best-effort). Caller handles failure.
    func deleteWHEPSession(sessionURL: URL, token: String) async throws
}
