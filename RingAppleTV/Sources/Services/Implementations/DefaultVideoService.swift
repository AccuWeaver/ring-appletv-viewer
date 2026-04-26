import Foundation

/// Production implementation of `VideoService` that requests live stream sessions
/// from Ring devices and validates session lifetimes.
final class DefaultVideoService: VideoService {

    // MARK: - Dependencies

    private let authService: AuthService
    private let apiClient: RingAPIClient

    // MARK: - Init

    init(authService: AuthService, apiClient: RingAPIClient) {
        self.authService = authService
        self.apiClient = apiClient
    }

    // MARK: - VideoService

    func requestLiveStream(for deviceId: Int) async throws -> StreamSession {
        let token = try await authService.getValidToken()
        let response = try await apiClient.requestLiveStream(deviceId: deviceId, token: token.accessToken)
        return response.toDomain()
    }

    func validateStreamSession(_ session: StreamSession) -> Bool {
        session.isValid
    }
}
