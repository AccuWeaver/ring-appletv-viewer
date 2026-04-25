import Foundation

/// Thin networking layer that communicates with Ring's private API.
/// All methods are async and throw `RingAPIError` on failure.
protocol RingAPIClient {
    func authenticate(email: String, password: String) async throws -> AuthTokenResponse
    func authenticate(email: String, password: String, twoFactorCode: String) async throws -> AuthTokenResponse
    func refreshToken(_ refreshToken: String) async throws -> AuthTokenResponse
    func fetchDevices(token: String) async throws -> [RingDeviceResponse]
    func requestLiveStream(deviceId: Int, token: String) async throws -> StreamSessionResponse
    func fetchEvents(deviceId: Int, token: String, limit: Int) async throws -> [RingEventResponse]
    func fetchEventVideoURL(eventId: Int, token: String) async throws -> URL
}
