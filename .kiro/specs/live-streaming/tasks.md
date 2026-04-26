# Live Streaming & Snapshot Capture — Tasks

## Phase 1: Camera Snapshots

### Task 1: Add snapshot API endpoints to RingAPIClient
- [ ] Add `fetchSnapshot(deviceId:token:) async throws -> Data` to `RingAPIClient` protocol
- [ ] Add `requestSnapshot(deviceId:token:) async throws` to `RingAPIClient` protocol
- [ ] Implement in `DefaultRingAPIClient`:
  - GET `https://api.ring.com/clients_api/snapshots/image/{deviceId}` → returns raw JPEG `Data`
  - POST `https://api.ring.com/clients_api/doorbots/{deviceId}/snapshot` → triggers new capture
- [ ] Handle non-image responses gracefully (404, empty body)

### Task 2: Create SnapshotService
- [ ] Define `SnapshotService` protocol with `getSnapshot(for:)`, `requestNewSnapshot(for:)`, `clearCache()`
- [ ] Implement `DefaultSnapshotService` with:
  - `NSCache<NSNumber, NSData>` for in-memory caching
  - 60-second TTL per snapshot
  - Parallel fetch support (don't duplicate in-flight requests for same device)
- [ ] Wire into `ServiceContainer`

### Task 3: Update DashboardViewModel with snapshot support
- [ ] Add `@Published var snapshots: [Int: Data]` dictionary
- [ ] After `loadDevices()` succeeds, fetch snapshots for all devices in parallel
- [ ] Include snapshot refresh in the existing 60-second background refresh timer
- [ ] Handle individual snapshot failures without affecting other devices

### Task 4: Update DeviceCardView to display snapshots
- [ ] Accept optional `snapshotData: Data?` parameter
- [ ] When snapshot data is available, display as background image (aspect-fill, 16:9)
- [ ] Keep gradient overlays for text readability over real images
- [ ] Keep placeholder icon when no snapshot available
- [ ] Update DashboardView to pass snapshot data from view model to each card

### Task 5: Add snapshot tests
- [ ] Unit tests for `DefaultSnapshotService` (cache hit, cache miss, TTL expiration)
- [ ] Unit tests for `DashboardViewModel` snapshot fetching
- [ ] Update `MockRingAPIClient` with snapshot method stubs
- [ ] Update `MockData` with sample snapshot data

## Phase 2: WebRTC Live Streaming

### Task 6: Integrate WebRTC framework
- [ ] Research and select WebRTC framework for tvOS (Google WebRTC or alternative)
- [ ] Add as Swift Package dependency or vendored framework
- [ ] Verify it compiles and links for tvOS simulator and device

### Task 7: Implement SIP signaling client
- [ ] Create `SIPSignalingClient` that connects to Ring's SIP server over TLS
- [ ] Implement SIP INVITE with SDP offer from WebRTC peer connection
- [ ] Handle SIP 200 OK response with remote SDP answer
- [ ] Handle ICE candidate exchange via SIP INFO messages

### Task 8: Implement WebRTCStreamService
- [ ] Define `WebRTCStreamService` protocol
- [ ] Implement `DefaultWebRTCStreamService`:
  - Create `RTCPeerConnection` with appropriate configuration
  - Generate SDP offer, send via SIP
  - Apply remote SDP answer
  - Handle ICE candidates
  - Extract video track for rendering
- [ ] Implement connection state management and timeout handling

### Task 9: Create WebRTC video renderer view
- [ ] Create `WebRTCVideoView` as `UIViewRepresentable` wrapping `RTCMTLVideoView`
- [ ] Handle video track attachment/detachment
- [ ] Support full-screen rendering with proper aspect ratio

### Task 10: Update PlayerView for WebRTC
- [ ] Replace the "not yet supported" placeholder with `WebRTCVideoView` when session is SIP
- [ ] Show connection progress during WebRTC setup
- [ ] Handle stream end/timeout with restart option
- [ ] Clean up WebRTC resources on view disappear

### Task 11: Add WebRTC tests
- [ ] Mock `WebRTCStreamService` for `PlayerViewModel` tests
- [ ] Test connection state transitions (connecting → connected → disconnected)
- [ ] Test error handling (timeout, signaling failure, ICE failure)
- [ ] Test session expiration handling
