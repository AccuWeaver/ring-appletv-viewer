import Foundation

/// Requests and validates HLS live stream sessions from Ring devices.
protocol VideoService {
    func requestLiveStream(for deviceId: Int) async throws -> StreamSession
    func validateStreamSession(_ session: StreamSession) -> Bool
}
