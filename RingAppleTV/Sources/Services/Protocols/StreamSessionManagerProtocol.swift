import Foundation
import Combine

/// Manages the full WHEP + WebRTC live stream lifecycle.
///
/// Replaces `WebRTCStreamService` — uses WHEP (HTTP POST/DELETE) for SDP exchange
/// instead of SIP signaling. The `RTCPeerConnection` is managed internally.
protocol StreamSessionManagerProtocol: AnyObject, Sendable {
    /// Start a live stream for a device. Creates a WHEP session and establishes
    /// a WebRTC peer connection in receive-only mode.
    func startStream(deviceId: String, powerSource: PowerSource) async throws

    /// Stop the current stream. Sends a best-effort DELETE to the WHEP session
    /// and closes the local `RTCPeerConnection`.
    func stopStream() async

    /// The current WebRTC connection state.
    var connectionState: WebRTCConnectionState { get }

    /// Publisher for observing connection state changes.
    var connectionStatePublisher: Published<WebRTCConnectionState>.Publisher { get }
}
