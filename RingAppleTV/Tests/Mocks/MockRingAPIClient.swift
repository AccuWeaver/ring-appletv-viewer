import Foundation
@testable import RingAppleTV

/// Mock `RingAPIClient` with configurable return values and call tracking.
final class MockRingAPIClient: RingAPIClient {

    // MARK: - authenticate(email:password:)

    var authenticateResult: Result<AuthTokenResponse, Error> = .failure(RingAPIError.unknown("not configured"))
    var authenticateCalls: [(email: String, password: String)] = []

    func authenticate(email: String, password: String) async throws -> AuthTokenResponse {
        authenticateCalls.append((email: email, password: password))
        return try authenticateResult.get()
    }

    // MARK: - authenticate(email:password:twoFactorCode:)

    var authenticateWith2FAResult: Result<AuthTokenResponse, Error> = .failure(RingAPIError.unknown("not configured"))
    var authenticateWith2FACalls: [(email: String, password: String, code: String)] = []

    func authenticate(email: String, password: String, twoFactorCode: String) async throws -> AuthTokenResponse {
        authenticateWith2FACalls.append((email: email, password: password, code: twoFactorCode))
        return try authenticateWith2FAResult.get()
    }

    // MARK: - refreshToken

    var refreshTokenResult: Result<AuthTokenResponse, Error> = .failure(RingAPIError.tokenRefreshFailed)
    var refreshTokenCalls: [String] = []

    func refreshToken(_ refreshToken: String) async throws -> AuthTokenResponse {
        refreshTokenCalls.append(refreshToken)
        return try refreshTokenResult.get()
    }

    // MARK: - fetchDevices

    var fetchDevicesResult: Result<[RingDeviceResponse], Error> = .success([])

    func fetchDevices(token: String) async throws -> [RingDeviceResponse] {
        try fetchDevicesResult.get()
    }

    // MARK: - requestLiveStream

    var requestLiveStreamResult: Result<StreamSessionResponse, Error> = .failure(RingAPIError.streamUnavailable)

    func requestLiveStream(deviceId: Int, token: String) async throws -> StreamSessionResponse {
        try requestLiveStreamResult.get()
    }

    // MARK: - fetchEvents

    var fetchEventsResult: Result<[RingEventResponse], Error> = .success([])

    func fetchEvents(deviceId: Int, token: String, limit: Int) async throws -> [RingEventResponse] {
        try fetchEventsResult.get()
    }

    // MARK: - fetchEventVideoURL

    var fetchEventVideoURLResult: Result<URL, Error> = .failure(RingAPIError.unknown("not configured"))

    func fetchEventVideoURL(eventId: Int, token: String) async throws -> URL {
        try fetchEventVideoURLResult.get()
    }

    // MARK: - fetchSnapshot

    var fetchSnapshotResult: Result<Data, Error> = .failure(RingAPIError.noSnapshotAvailable)
    var fetchSnapshotCalls: [(deviceId: Int, token: String)] = []

    func fetchSnapshot(deviceId: Int, token: String) async throws -> Data {
        fetchSnapshotCalls.append((deviceId: deviceId, token: token))
        return try fetchSnapshotResult.get()
    }

    // MARK: - requestSnapshot

    var requestSnapshotResult: Result<Void, Error> = .success(())
    var requestSnapshotCalls: [(deviceId: Int, token: String)] = []

    func requestSnapshot(deviceId: Int, token: String) async throws {
        requestSnapshotCalls.append((deviceId: deviceId, token: token))
        try requestSnapshotResult.get()
    }
}
