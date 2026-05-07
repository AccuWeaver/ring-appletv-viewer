# WebRTC Live Streaming — Design Document

**Feature Name**: WebRTC Live Streaming
**Version**: 1.0
**Last Updated**: April 2026
**Depends On**: Camera Snapshots spec

## Architecture

### WebRTC Live Stream Pipeline

```text
RingAPIClient.requestLiveStream() → StreamSessionResponse (SIP details)
    ↓
SIPSignalingClient → establishes SIP session over TLS
    ↓ sends SIP INVITE with local SDP offer
    ↓ receives SIP 200 OK with remote SDP answer
    ↓ exchanges ICE candidates via SIP INFO
WebRTCClient → creates RTCPeerConnection
    ↓ applies local/remote SDP
    ↓ gathers and applies ICE candidates
    ↓ extracts RTCVideoTrack from media stream
RTCMTLVideoView → Metal-backed video renderer
    ↓
WebRTCVideoView (UIViewRepresentable) → SwiftUI wrapper
    ↓
PlayerView → full-screen playback with overlays
```

## Components

### New: `SIPSignalingClient`

```swift
/// Handles SIP signaling over TLS to Ring's media server.
final class SIPSignalingClient {
    /// Connect to Ring's SIP server and perform INVITE/200 OK exchange.
    func connect(
        to server: String,
        port: Int,
        sessionId: String,
        localSDP: String
    ) async throws -> SIPSignalingResult

    /// Send ICE candidate via SIP INFO message.
    func sendICECandidate(_ candidate: String) async throws

    /// Send SIP BYE to cleanly end the session.
    func disconnect() async

    struct SIPSignalingResult {
        let remoteSDP: String
        let iceCandidates: [String]
    }
}
```

Uses `NWConnection` (Network.framework) for TLS socket communication to the SIP server.

### New Protocol: `WebRTCStreamService`

```swift
protocol WebRTCStreamService: AnyObject {
    /// Connect to a live stream using the SIP session details.
    func connect(session: StreamSessionResponse) async throws

    /// Disconnect and clean up all WebRTC resources.
    func disconnect()

    /// The current video track for rendering. Nil until connected.
    var videoTrack: RTCVideoTrack? { get }

    /// Observable connection state.
    var connectionState: WebRTCConnectionState { get }

    /// Publisher for connection state changes.
    var connectionStatePublisher: Published<WebRTCConnectionState>.Publisher { get }
}

enum WebRTCConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
```

### New Implementation: `DefaultWebRTCStreamService`

```swift
final class DefaultWebRTCStreamService: NSObject, WebRTCStreamService {
    @Published private(set) var connectionState: WebRTCConnectionState = .disconnected

    private var peerConnection: RTCPeerConnection?
    private var signalingClient: SIPSignalingClient?
    private var sessionTimer: Task<Void, Never>?

    // RTCPeerConnectionDelegate callbacks drive state transitions:
    // .new → .connecting
    // .connected → .connected
    // .failed → .failed(message)
    // .closed → .disconnected
}
```

Key behaviors:
1. `connect(session:)` creates `RTCPeerConnection`, generates SDP offer
2. Passes SDP offer to `SIPSignalingClient` which sends SIP INVITE
3. Receives remote SDP answer from SIP 200 OK, applies to peer connection
4. ICE candidates exchanged via SIP INFO messages
5. Once connected, extracts `RTCVideoTrack` from first media stream
6. Starts session timer based on `expiresIn`
7. `disconnect()` sends SIP BYE, closes peer connection, cancels timer

### New: `WebRTCVideoView`

```swift
/// SwiftUI wrapper for RTCMTLVideoView (Metal-backed WebRTC video renderer).
struct WebRTCVideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView { ... }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // Attach/detach video track as it changes
    }
}
```

### Updated `PlayerViewModel`

Add WebRTC stream service dependency:

```swift
@MainActor
final class PlayerViewModel: ObservableObject {
    private let videoService: VideoService
    private let webRTCService: WebRTCStreamService?  // nil if framework unavailable

    @Published var connectionState: WebRTCConnectionState = .disconnected

    func startWebRTCStream(session: StreamSessionResponse) async { ... }
    func stopStream() { ... }
}
```

### Updated `PlayerView`

Replace the "not yet supported" placeholder:

```swift
if session.isSipSession {
    if let webRTCService = viewModel.webRTCService {
        // WebRTC available — show live video
        switch viewModel.connectionState {
        case .connecting:
            // Loading overlay with snapshot backdrop
        case .connected:
            WebRTCVideoView(videoTrack: webRTCService.videoTrack)
            deviceNameOverlay
        case .failed(let message):
            errorOverlay(message: message)
        case .disconnected:
            // Stream ended overlay with restart option
        }
    } else {
        // WebRTC not available — show snapshot + "not yet supported" (from Snapshots spec)
    }
}
```

### Updated `ServiceContainer`

```swift
// Conditionally create WebRTC service (only if framework is available)
let webRTCService: WebRTCStreamService? = WebRTCFrameworkAvailable
    ? DefaultWebRTCStreamService()
    : nil

// Update PlayerViewModel factory:
func makePlayerViewModel() -> PlayerViewModel {
    PlayerViewModel(videoService: videoService, webRTCService: webRTCService)
}
```

## Data Flow

### Live Stream Sequence

1. User taps camera card → navigates to `PlayerView`
2. `PlayerViewModel.requestStream(for:)` calls `videoService.requestLiveStream(for:)`
3. API returns `StreamSessionResponse` with SIP details
4. If `webRTCService` is available, calls `webRTCService.connect(session:)`
5. `DefaultWebRTCStreamService` creates `RTCPeerConnection`, generates SDP offer
6. `SIPSignalingClient` sends SIP INVITE to `sip_server_ip:sip_server_port` over TLS
7. Receives SIP 200 OK with remote SDP answer
8. Applies remote SDP, exchanges ICE candidates
9. WebRTC peer connection established → `connectionState = .connected`
10. `RTCVideoTrack` extracted → `WebRTCVideoView` renders video frames
11. Session timer starts counting down from `expiresIn`
12. On timeout: `disconnect()` called, UI shows "Stream ended" with restart option
13. On user navigation away: `disconnect()` called, resources cleaned up

## Error Handling

| Scenario | Behavior |
| --- | --- |
| WebRTC framework not available | Show snapshot backdrop + "not yet supported" overlay |
| SIP connection timeout (30s) | Show "Unable to connect" with retry button |
| SIP signaling failure | Show "Unable to connect to camera" with retry |
| ICE candidate failure | Show "Network configuration error" with retry |
| WebRTC connection drops | Show "Connection lost" with reconnect option |
| Session expires | Show "Stream ended" with option to start new session |
| Peer connection fails | Show error message from `WebRTCConnectionState.failed` |

## Testing Strategy

### Unit Tests

- Mock `WebRTCStreamService` for `PlayerViewModel` tests
- Test connection state transitions: `disconnected → connecting → connected → disconnected`
- Test error state: `disconnected → connecting → failed`
- Test session expiration triggers disconnect
- Test `disconnect()` is called on view disappear

### Property-Based Tests

- **CP-1 (Resource Cleanup)**: After `disconnect()`, all resource references (peer connection, video track, SIP client) are nil.
- **CP-2 (Session Expiration)**: For any `expiresIn` value, the stream is terminated at or before the deadline.
- **CP-3 (State Machine)**: For any sequence of events, only valid state transitions occur.
