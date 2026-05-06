# WebRTC Live Streaming — Tasks

**Note**: Task 1 is a spike with a go/no-go decision. If the spike fails (no viable WebRTC framework for tvOS), Tasks 2–6 should not be implemented.

## Task 1: WebRTC framework spike (go/no-go gate)

- [x] 1.1 Attempt to build Google's WebRTC framework for tvOS (arm64 + simulator) from source
- [x] 1.2 If Google WebRTC fails, evaluate AmazonChimeSDK for tvOS compatibility
- [x] 1.3 If a viable framework is found, add it as a Swift Package dependency or vendored framework in `Package.swift`
- [x] 1.4 Create a minimal proof-of-concept: instantiate `RTCPeerConnection` on tvOS simulator and verify it compiles and links
- [x] 1.5 Document findings and decision (go/no-go) — if no-go, pause this spec and document the companion service fallback approach

## Task 2: Implement SIP signaling client

- [x] 2.1 Create `SIPSignalingClient` in `Services/Implementations/SIPSignalingClient.swift`
- [x] 2.2 Use `NWConnection` (Network.framework) for TLS socket to Ring's SIP server
- [x] 2.3 Implement SIP INVITE with SDP offer payload
- [x] 2.4 Parse SIP 200 OK response to extract remote SDP answer
- [x] 2.5 Implement ICE candidate exchange via SIP INFO messages
- [x] 2.6 Implement SIP BYE for clean session teardown
- [x] 2.7 Handle connection timeouts (30 seconds)

## Task 3: Implement WebRTCStreamService

- [x] 3.1 Define `WebRTCStreamService` protocol in `Services/Protocols/WebRTCStreamServiceProtocol.swift`
- [x] 3.2 Implement `DefaultWebRTCStreamService` in `Services/Implementations/DefaultWebRTCStreamService.swift`:
  - Create `RTCPeerConnection` with STUN/TURN configuration
  - Generate SDP offer via `RTCPeerConnection`
  - Send offer through `SIPSignalingClient`, apply remote SDP answer
  - Handle ICE candidates from both local gathering and SIP INFO
  - Extract `RTCVideoTrack` from first media stream
- [x] 3.3 Implement `WebRTCConnectionState` enum and state machine with valid transitions only
- [x] 3.4 Implement session timer that calls `disconnect()` when `expiresIn` elapses
- [x] 3.5 Implement `disconnect()` that sends SIP BYE, closes peer connection, releases all resources, cancels timer
- [x] 3.6 Wire into `ServiceContainer` (conditionally, only if framework is available)

## Task 4: Create WebRTC video renderer view

- [x] 4.1 Create `WebRTCVideoView` as `UIViewRepresentable` wrapping `RTCMTLVideoView`
- [x] 4.2 Handle video track attachment when track becomes available
- [x] 4.3 Handle video track detachment on disconnect
- [x] 4.4 Support full-screen rendering with proper aspect ratio (aspect-fit within bounds)

## Task 5: Update PlayerView and PlayerViewModel for WebRTC

- [x] 5.1 Add optional `webRTCService: WebRTCStreamService?` dependency to `PlayerViewModel`
- [x] 5.2 Add `@Published var connectionState: WebRTCConnectionState` to `PlayerViewModel`
- [x] 5.3 Subscribe to `webRTCService.connectionStatePublisher` to update published state
- [x] 5.4 Implement `startWebRTCStream(session:)` and `stopStream()` methods
- [x] 5.5 Call `stopStream()` in `PlayerView.onDisappear` for resource cleanup
- [x] 5.6 Update `PlayerView` to show `WebRTCVideoView` when connected, loading overlay when connecting, error overlay when failed
- [x] 5.7 Update `ServiceContainer.makePlayerViewModel()` to pass `webRTCService`

## Task 6: Add WebRTC tests

- [x] 6.1 Create `MockWebRTCStreamService` in `Tests/Mocks/` with configurable state and video track
- [x] 6.2 Unit tests for `PlayerViewModel`: connection state transitions (connecting → connected → disconnected)
- [x] 6.3 Unit tests for `PlayerViewModel`: error handling (connecting → failed)
- [x] 6.4 Unit tests for `PlayerViewModel`: session expiration triggers disconnect
- [x] 6.5 Unit tests for `PlayerViewModel`: `stopStream()` called on view disappear
- [x] 6.6 Property test for CP-1 (Resource Cleanup): after `disconnect()`, all resource references are nil
- [x] 6.7 Property test for CP-3 (State Machine): for any sequence of delegate callbacks, only valid state transitions occur
