import Foundation

/// Result of a successful simulator live-HLS handshake. The caller is
/// responsible for releasing the backend-side session via
/// `releaseSession(_:)` when the player tears down.
struct SimulatorLiveStream: Equatable {
    /// Playable `.m3u8` URL served by mediamtx.
    let url: URL
    /// Backend session id, required for `DELETE /mock/session/{id}`.
    let sessionId: String
}

/// Establishes a live stream that plays on the tvOS simulator by routing
/// Ring's SIP/RTP feed through mediamtx as HLS. When the underlying sidecar
/// cannot produce a stream the call throws and the caller should fall back
/// to a recorded event or the test pattern.
protocol SimulatorLiveStreamService: Sendable {
    /// Ask the backend to start the SIP bridge for `deviceId` and hand back
    /// the mediamtx HLS URL. Throws on any backend-side failure.
    func startStream(deviceId: String) async throws -> SimulatorLiveStream

    /// Release a previously started stream. Best-effort — callers should not
    /// block teardown on the result.
    func releaseSession(_ sessionId: String) async
}
