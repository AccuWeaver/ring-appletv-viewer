# Live Streaming & Snapshot Capture — Requirements

**Feature Name**: Live Streaming & Snapshot Capture
**Version**: 1.0
**Last Updated**: April 2026

## Overview

Enable live video streaming from Ring cameras on Apple TV and display camera snapshot thumbnails on the dashboard. Ring's API uses SIP/WebRTC for live streams (not HLS), so this feature requires implementing a WebRTC-based video pipeline. Additionally, Ring provides snapshot endpoints that return the most recent camera image — these should be displayed on the dashboard device cards.

## Research Summary

Ring's live streaming architecture (based on reverse-engineering by `ring-client-api` and `ring-mqtt`):

1. **Live Stream Protocol**: Ring uses SIP signaling over TLS to establish a WebRTC media session. The POST to `/clients_api/doorbots/{id}/live_view` returns SIP connection details (`sip_server_ip`, `sip_server_port`, `sip_session_id`, etc.). The client must then establish a WebRTC peer connection using these SIP parameters.

2. **Stream Pipeline (reference implementations)**:
   - `ring-client-api` (TypeScript): Uses `werift` (pure JS WebRTC) to connect via SIP, then pipes the RTP media to `ffmpeg` or `go2rtc` for transcoding to RTSP/HLS.
   - `ring-mqtt`: Uses `go2rtc` as a local media server that handles the WebRTC-to-RTSP conversion, making streams available as `rtsp://` URLs that any player can consume.

3. **Snapshot API**: Ring provides a snapshot endpoint at `https://app-snaps.ring.com/snapshots/next/{device_id}` (or via `https://api.ring.com/clients_api/snapshots/image/{device_id}`) that returns the most recent JPEG snapshot. A new snapshot can be requested via POST to `/clients_api/doorbots/{device_id}/snapshot`.

4. **tvOS Constraints**: tvOS does not include a native WebRTC framework. Options:
   - Use Google's WebRTC framework (`WebRTC.framework`) compiled for tvOS
   - Run a local proxy (not practical on tvOS)
   - Use a companion service approach (Mac/server runs the WebRTC-to-HLS bridge)

## Functional Requirements

### FR-1: Camera Snapshots on Dashboard

**Priority**: High (can be implemented independently of live streaming)

#### FR-1.1: Snapshot Retrieval

- System shall fetch the latest snapshot image for each camera device
- System shall use Ring's snapshot API endpoint to retrieve JPEG images
- System shall cache snapshots locally to avoid redundant network requests
- System shall refresh snapshots periodically (every 60 seconds when dashboard is visible)
- System shall handle cameras that don't have a recent snapshot gracefully (show placeholder)

#### FR-1.2: Snapshot Display

- Dashboard device cards shall display the camera's latest snapshot as the card background
- Snapshots shall fill the 16:9 card area with aspect-fill scaling
- A gradient overlay shall ensure device name and status text remain readable over the snapshot
- Snapshot loading shall not block the dashboard from rendering (async image loading)

### FR-2: Live Video Streaming

**Priority**: High

#### FR-2.1: WebRTC Session Establishment

- System shall use the SIP session details from Ring's live view API to establish a WebRTC peer connection
- System shall handle SIP signaling over TLS to the Ring media server
- System shall support the ICE candidate exchange required for WebRTC connectivity
- System shall handle session timeouts (default 10 minutes per Ring's `expires_in`)

#### FR-2.2: Video Rendering

- System shall render the incoming WebRTC video track in a full-screen player view
- System shall display the device name overlay during playback
- System shall provide loading state while the WebRTC connection is being established
- Video quality shall adapt based on available bandwidth (WebRTC handles this natively)

#### FR-2.3: Stream Lifecycle

- System shall automatically end the stream when the session expires
- System shall provide a retry option if the stream fails to connect
- System shall cleanly tear down the WebRTC connection when the user navigates away
- System shall handle network interruptions with appropriate error messaging

### FR-3: Fallback Behavior

**Priority**: Medium

#### FR-3.1: WebRTC Unavailable

- If WebRTC framework is not available, system shall display a clear message explaining the limitation
- System shall still allow snapshot viewing and event history access
- The "not yet supported" message shall include guidance on what's needed

## Technical Requirements

### TR-1: WebRTC Framework

- Use Google's WebRTC framework for tvOS (or a Swift WebRTC wrapper)
- Framework must support: SDP offer/answer, ICE candidates, video track rendering
- Consider `AmazonChimeSDK` or `WebRTC.framework` (prebuilt for Apple platforms)

### TR-2: Snapshot API Integration

- Endpoint: `GET https://api.ring.com/clients_api/snapshots/image/{device_id}`
- Auth: Bearer token in Authorization header
- Response: JPEG image data
- New snapshot request: `POST https://api.ring.com/clients_api/doorbots/{device_id}/snapshot`

### TR-3: Image Caching

- Use `NSCache` or a simple disk cache for snapshot images
- Cache TTL: 60 seconds (matches refresh interval)
- Maximum cache size: 50 MB

## Implementation Phases

### Phase 1: Snapshots (implement first)
- Add snapshot API endpoints to `RingAPIClient`
- Create `SnapshotService` for fetching and caching images
- Update `DeviceCardView` to display snapshot images
- Add periodic refresh

### Phase 2: WebRTC Live Streaming
- Integrate WebRTC framework for tvOS
- Implement SIP signaling client
- Build WebRTC video renderer view
- Update `PlayerView` to use WebRTC instead of placeholder

## Reference Implementations

- `ring-client-api` (TypeScript): [github.com/dgreif/ring](https://github.com/dgreif/ring) — SIP/WebRTC streaming via `werift`
- `ring-mqtt` (Node.js): [github.com/tsightler/ring-mqtt](https://github.com/tsightler/ring-mqtt) — Uses `go2rtc` for WebRTC-to-RTSP
- `python-ring-doorbell` (Python): [github.com/python-ring-doorbell/python-ring-doorbell](https://github.com/python-ring-doorbell/python-ring-doorbell) — Snapshot and event APIs
