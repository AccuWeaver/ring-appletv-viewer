# WebRTC Live Streaming — Tasks

**Note**: Task 1 is a spike with a go/no-go decision. If the spike fails (no viable WebRTC framework for tvOS), Tasks 2–6 should not be implemented.

## Task 1: WebRTC framework spike (go/no-go gate)

- [ ] 1.1 Attempt to build Google's WebRTC framework for tvOS (arm64 + simulator) from source
- [ ] 1.2 If Google WebRTC fails, evaluate AmazonChimeSDK for tvOS compatibility
- [ ] 1.3 If a viable framework is found, add it as a Swift Package dependency or vendored framework in `Package.swift`
- [ ] 1.4 Create a minimal proof-of-concept: instantiate `RTCPeerConnection` on tvOS simulator and verify it compiles and links
- [ ] 1.5 Document findings and decision (go/no-go) — if no-go, pause this spec and document the companion service fallback approach

## Task 2: Implement SIP signaling client

- [ ] 2.1 Create `SIPSignalingClient` in `Services/Implementations/SIPSignalingClient.swift`
- [ ] 2.2 Use `NWConnection` (Network.framework) for TLS socket to Ring's SIP server
- [ ] 2.3 Implement SIP INVITE with SDP offer payload
- [ ] 2.4 Parse SIP 200 OK response to extract remote SDP answer
- [ ] 2.5 Implement ICE candidate exchange via SIP INFO messages
- [ ] 2.6 Implement SIP BYE for clean session teardown
- [ ] 2.7 Handle connection timeouts (30 seconds)

## Task 3: Implement WebRTCStreamService

- [ ] 3.1 Define `WebRTCStreamService` protocol in `Services/Protocols/WebRTCStreamServiceProtocol.swift`
- [ ] 3.2 Implement `DefaultWebRTCStreamService` in `Services/Implementations/DefaultWebRTCStreamService.swift`:
  - Create `RTCPeerConnection` with STUN/TURN configuration
  - Generate SDP offer via `RTCPeerConnection`
  - Send offer through `SIPSignalingClient`, apply remote SDP answer
  - Handle ICE candidates from both local gathering and SIP INFO
  - Extract `RTCVideoTrack` from first media stream
- [ ] 3.3 Implement `WebRTCConnectionState` enum and state machine with valid transitions only
- [ ] 3.4 Implement session timer that calls `disconnect()` when `expiresIn` elapses
- [ ] 3.5 Implement `disconnect()` that sends SIP BYE, closes peer connection, releases all resources, cancels timer
- [ ] 3.6 Wire into `ServiceContainer` (conditionally, only if framework is available)

## Task 4: Create WebRTC video renderer view

- [ ] 4.1 Create `WebRTCVideoView` as `UIViewRepresentable` wrapping `RTCMTLVideoView`
- [ ] 4.2 Handle video track attachment when track becomes available
- [ ] 4.3 Handle video track detachment on disconnect
- [ ] 4.4 Support full-screen rendering with proper aspect ratio (aspect-fit within bounds)

## Task 5: Update PlayerView and PlayerViewModel for WebRTC

- [ ] 5.1 Add optional `webRTCService: WebRTCStreamService?` dependency to `PlayerViewModel`
- [ ] 5.2 Add `@Published var connectionState: WebRTCConnectionState` to `PlayerViewModel`
- [ ] 5.3 Subscribe to `webRTCService.connectionStatePublisher` to update published state
- [ ] 5.4 Implement `startWebRTCStream(session:)` and `stopStream()` methods
- [ ] 5.5 Call `stopStream()` in `PlayerView.onDisappear` for resource cleanup
- [ ] 5.6 Update `PlayerView` to show `WebRTCVideoView` when connected, loading overlay when connecting, error overlay when failed
- [ ] 5.7 Update `ServiceContainer.makePlayerViewModel()` to pass `webRTCService`

## Task 6: Add WebRTC tests

- [ ] 6.1 Create `MockWebRTCStreamService` in `Tests/Mocks/` with configurable state and video track
- [ ] 6.2 Unit tests for `PlayerViewModel`: connection state transitions (connecting → connected → disconnected)
- [ ] 6.3 Unit tests for `PlayerViewModel`: error handling (connecting → failed)
- [ ] 6.4 Unit tests for `PlayerViewModel`: session expiration triggers disconnect
- [ ] 6.5 Unit tests for `PlayerViewModel`: `stopStream()` called on view disappear
- [ ] 6.6 Property test for CP-1 (Resource Cleanup): after `disconnect()`, all resource references are nil
- [ ] 6.7 Property test for CP-3 (State Machine): for any sequence of delegate callbacks, only valid state transitions occur
