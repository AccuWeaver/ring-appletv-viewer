# Live Streaming & Snapshot Capture — Design Document

**Feature Name**: Live Streaming & Snapshot Capture
**Version**: 1.0
**Last Updated**: April 2026

## Architecture

### Snapshot Pipeline

```
RingAPIClient.fetchSnapshot(deviceId:token:) → Data (JPEG)
    ↓
SnapshotService.getSnapshot(for:) → UIImage?
    ↓ (caches in NSCache + disk)
DashboardViewModel → publishes snapshots dict
    ↓
DeviceCardView → AsyncImage-style display
```

### WebRTC Live Stream Pipeline

```
RingAPIClient.requestLiveStream() → StreamSessionResponse (SIP details)
    ↓
SIPSignalingClient → establishes SIP session over TLS
    ↓
WebRTCClient → creates RTCPeerConnection, exchanges SDP/ICE
    ↓
RTCVideoTrack → rendered in RTCMTLVideoView (Metal-backed)
    ↓
PlayerView → wraps in UIViewRepresentable for SwiftUI
```

## Components

### Phase 1: Snapshots

#### New Protocol: `SnapshotService`

```swift
protocol SnapshotService {
    /// Fetch the latest snapshot for a device. Returns cached if fresh.
    func getSnapshot(for deviceId: Int) async throws -> Data
    /// Request Ring to capture a new snapshot.
    func requestNewSnapshot(for deviceId: Int) async throws
    /// Clear all cached snapshots.
    func clearCache()
}
```

#### New API Client Methods

```swift
// Add to RingAPIClient protocol:
func fetchSnapshot(deviceId: Int, token: String) async throws -> Data
func requestSnapshot(deviceId: Int, token: String) async throws
```

#### Updated DeviceCardView

- Accept optional `snapshotData: Data?` parameter
- Display as background image when available using `Image(uiImage:)`
- Fall back to current placeholder when nil

#### Updated DashboardViewModel

- Maintain `@Published var snapshots: [Int: Data]` dictionary (deviceId → JPEG data)
- Fetch snapshots in parallel after devices load
- Refresh snapshots on the same 60-second timer as device refresh

### Phase 2: WebRTC Streaming

#### New: `WebRTCStreamService`

```swift
protocol WebRTCStreamService {
    func connect(session: StreamSessionResponse) async throws -> WebRTCStream
    func disconnect()
    var videoTrack: RTCVideoTrack? { get }
    var connectionState: WebRTCConnectionState { get }
}

enum WebRTCConnectionState {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
```

#### New: `SIPSignalingClient`

Handles the SIP INVITE/ACK flow over TLS to Ring's media server using the session details from the live view API response.

#### Updated PlayerView

- When `session.isSipSession`, use `WebRTCVideoView` (UIViewRepresentable wrapping `RTCMTLVideoView`)
- Show connection progress during WebRTC setup
- Handle disconnect/reconnect

## Data Flow

### Snapshot Fetch Sequence

1. `DashboardViewModel.loadDevices()` completes with device list
2. For each device, call `snapshotService.getSnapshot(for: device.id)`
3. `SnapshotService` checks NSCache → if fresh, return cached
4. If stale/missing, call `apiClient.fetchSnapshot(deviceId:token:)`
5. Store in cache, publish to view model
6. `DeviceCardView` renders snapshot as card background

### Live Stream Sequence

1. User taps camera card → `PlayerViewModel.requestStream(for:)`
2. API returns `StreamSessionResponse` with SIP details
3. `WebRTCStreamService.connect(session:)` initiates SIP signaling
4. SIP INVITE sent to `sip_server_ip:sip_server_port` over TLS
5. SDP offer/answer exchanged, ICE candidates gathered
6. WebRTC peer connection established, video track starts
7. `RTCMTLVideoView` renders video frames
8. On timeout/disconnect, clean up peer connection

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Snapshot fetch fails | Show placeholder, retry on next refresh cycle |
| Snapshot 404 | Camera may not support snapshots — show placeholder permanently |
| WebRTC connection timeout | Show error with retry button |
| SIP signaling failure | Show "Unable to connect" with retry |
| ICE candidate failure | Show "Network configuration error" |
| Stream expires | Show "Stream ended" with option to restart |
| WebRTC framework missing | Show informational message (current behavior) |

## Testing Strategy

### Snapshot Tests
- Mock `RingAPIClient.fetchSnapshot` to return test JPEG data
- Verify `SnapshotService` caching behavior (cache hit, cache miss, expiration)
- Verify `DashboardViewModel` publishes snapshots after device load

### WebRTC Tests (Phase 2)
- Mock `WebRTCStreamService` for PlayerViewModel tests
- Test connection state transitions
- Test timeout and error handling
