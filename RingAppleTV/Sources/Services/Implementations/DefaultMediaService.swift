import Foundation

/// Production implementation of `MediaService` that downloads video clips and
/// snapshot images from the Ring Partner API.
///
/// Consolidates the functionality of the former `VideoService` and `SnapshotService`.
final class DefaultMediaService: MediaService, @unchecked Sendable {

    // MARK: - Dependencies

    private let authService: AuthService
    private let partnerAPIClient: PartnerAPIClientProtocol

    // MARK: - Init

    init(authService: AuthService, partnerAPIClient: PartnerAPIClientProtocol) {
        self.authService = authService
        self.partnerAPIClient = partnerAPIClient
    }

    // MARK: - MediaService

    func downloadVideo(deviceId: String, eventId: String) async throws -> URL {
        let token = try await authService.getValidToken()
        return try await partnerAPIClient.downloadVideo(
            deviceId: deviceId,
            eventId: eventId,
            token: token.accessToken
        )
    }

    func downloadSnapshot(deviceId: String) async throws -> Data {
        let token = try await authService.getValidToken()
        return try await partnerAPIClient.downloadSnapshot(
            deviceId: deviceId,
            token: token.accessToken
        )
    }
}
