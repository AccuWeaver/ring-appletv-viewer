import Foundation

/// Requests and validates HLS live stream sessions from Ring devices.
protocol VideoService {
    /// Request a new HLS live stream for the given device. Throws on failure or if the device is offline.
    func requestLiveStream(for deviceId: Int) async throws -> StreamSession
    /// Check whether a stream session still has remaining time.
    func validateStreamSession(_ session: StreamSession) -> Bool
}
