import Foundation
@testable import RingAppleTV

/// Full mock `PartnerAPIClientProtocol` with configurable responses and call tracking for all methods.
final class MockPartnerAPIClient: PartnerAPIClientProtocol, @unchecked Sendable {

    // MARK: - requestDeviceCode

    var requestDeviceCodeResult: Result<DeviceCodeResponse, Error> = .failure(PartnerAPIError.unauthorized)
    var requestDeviceCodeCalls: [String] = []

    func requestDeviceCode(clientId: String) async throws -> DeviceCodeResponse {
        requestDeviceCodeCalls.append(clientId)
        return try requestDeviceCodeResult.get()
    }

    // MARK: - pollForToken

    var pollForTokenResult: Result<AuthToken, Error> = .failure(PartnerAPIError.authorizationPending)
    var pollForTokenCalls: [(clientId: String, clientSecret: String, deviceCode: String)] = []

    func pollForToken(clientId: String, clientSecret: String, deviceCode: String) async throws -> AuthToken {
        pollForTokenCalls.append((clientId: clientId, clientSecret: clientSecret, deviceCode: deviceCode))
        return try pollForTokenResult.get()
    }

    // MARK: - refreshToken

    var refreshTokenResult: Result<AuthToken, Error> = .failure(PartnerAPIError.unauthorized)
    var refreshTokenCalls: [(clientId: String, clientSecret: String, refreshToken: String)] = []

    func refreshToken(clientId: String, clientSecret: String, refreshToken: String) async throws -> AuthToken {
        refreshTokenCalls.append((clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken))
        return try refreshTokenResult.get()
    }

    // MARK: - fetchDevices

    var fetchDevicesResult: Result<[PartnerDeviceResource], Error> = .success([])
    var fetchDevicesCalls: [String] = []

    func fetchDevices(token: String) async throws -> [PartnerDeviceResource] {
        fetchDevicesCalls.append(token)
        return try fetchDevicesResult.get()
    }

    // MARK: - fetchEvents

    var fetchEventsResult: Result<[PartnerEventResource], Error> = .success([])
    var fetchEventsCalls: [(deviceId: String, token: String, limit: Int)] = []

    func fetchEvents(deviceId: String, token: String, limit: Int) async throws -> [PartnerEventResource] {
        fetchEventsCalls.append((deviceId: deviceId, token: token, limit: limit))
        return try fetchEventsResult.get()
    }

    // MARK: - downloadVideo

    var downloadVideoResult: Result<URL, Error> = .failure(PartnerAPIError.notFound)
    var downloadVideoCalls: [(deviceId: String, eventId: String, token: String)] = []

    func downloadVideo(deviceId: String, eventId: String, token: String) async throws -> URL {
        downloadVideoCalls.append((deviceId: deviceId, eventId: eventId, token: token))
        return try downloadVideoResult.get()
    }

    // MARK: - downloadSnapshot

    var downloadSnapshotResult: Result<Data, Error> = .failure(PartnerAPIError.notFound)
    var downloadSnapshotCalls: [(deviceId: String, token: String)] = []

    func downloadSnapshot(deviceId: String, token: String) async throws -> Data {
        downloadSnapshotCalls.append((deviceId: deviceId, token: token))
        return try downloadSnapshotResult.get()
    }

    // MARK: - createWHEPSession

    var createWHEPSessionResult: Result<WHEPSessionResponse, Error> = .failure(PartnerAPIError.notFound)
    var createWHEPSessionCalls: [(deviceId: String, sdpOffer: String, token: String)] = []

    func createWHEPSession(deviceId: String, sdpOffer: String, token: String) async throws -> WHEPSessionResponse {
        createWHEPSessionCalls.append((deviceId: deviceId, sdpOffer: sdpOffer, token: token))
        return try createWHEPSessionResult.get()
    }

    // MARK: - deleteWHEPSession

    var deleteWHEPSessionResult: Result<Void, Error> = .success(())
    var deleteWHEPSessionCalls: [(sessionURL: URL, token: String)] = []

    func deleteWHEPSession(sessionURL: URL, token: String) async throws {
        deleteWHEPSessionCalls.append((sessionURL: sessionURL, token: token))
        try deleteWHEPSessionResult.get()
    }
}
