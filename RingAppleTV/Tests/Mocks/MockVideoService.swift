import Foundation
@testable import RingAppleTV

/// Mock `VideoService` with configurable return values and call tracking.
final class MockVideoService: VideoService {

    // MARK: - requestLiveStream

    var requestLiveStreamResult: Result<StreamSession, Error> = .failure(RingAPIError.streamUnavailable)
    var requestLiveStreamCalls: [Int] = []

    func requestLiveStream(for deviceId: Int) async throws -> StreamSession {
        requestLiveStreamCalls.append(deviceId)
        return try requestLiveStreamResult.get()
    }

    // MARK: - validateStreamSession

    var validateStreamSessionResult: Bool = true
    var validateStreamSessionCalls: [StreamSession] = []

    func validateStreamSession(_ session: StreamSession) -> Bool {
        validateStreamSessionCalls.append(session)
        return validateStreamSessionResult
    }
}
