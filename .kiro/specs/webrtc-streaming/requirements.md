# WebRTC Live Streaming — Requirements

**Feature Name**: WebRTC Live Streaming
**Version**: 1.0
**Last Updated**: April 2026
**Depends On**: Camera Snapshots spec (must be implemented first)

## Overview

Enable live video streaming from Ring cameras on Apple TV using WebRTC. Ring's API uses SIP signaling over TLS to establish WebRTC media sessions. This spec covers the WebRTC framework integration, SIP signaling client, video rendering, and stream lifecycle management.

This is a high-risk feature due to tvOS not including a native WebRTC framework. A framework spike (Task 1) must be completed with a go/no-go decision before proceeding with the remaining implementation.

## Research Summary

1. **Live Stream Protocol**: Ring uses SIP signaling over TLS to establish a WebRTC media session. The POST to `/clients_api/doorbots/{id}/live_view` returns SIP connection details (`sip_server_ip`, `sip_server_port`, `sip_session_id`, etc.). The client must then establish a WebRTC peer connection using these SIP parameters.

2. **Stream Pipeline (reference implementations)**:
   - `ring-client-api` (TypeScript): Uses `werift` (pure JS WebRTC) to connect via SIP, then pipes the RTP media to `ffmpeg` or `go2rtc` for transcoding.
   - `ring-mqtt` (Node.js): Uses `go2rtc` as a local media server that handles the WebRTC-to-RTSP conversion.

3. **tvOS Constraints**: tvOS does not include a native WebRTC framework. Options:
   - **Option A (preferred)**: Use Google's WebRTC framework (`WebRTC.framework`) compiled for tvOS — requires building from source or finding a prebuilt tvOS binary.
   - **Option B**: Use `AmazonChimeSDK` which wraps WebRTC and may have tvOS support.
   - **Option C (fallback)**: Companion service approach — a Mac/server runs the WebRTC-to-HLS bridge, and the Apple TV consumes the HLS stream via AVPlayer.

## Functional Requirements

### FR-1: WebRTC Framework Spike

**Priority**: Critical (gate for all other requirements)

- **FR-1.1**: Evaluate whether Google's WebRTC framework can be compiled for tvOS (arm64 + simulator).
- **FR-1.2**: If Google WebRTC is not viable, evaluate AmazonChimeSDK for tvOS.
- **FR-1.3**: If neither is viable, document the companion service fallback approach and pause this spec.
- **FR-1.4**: Produce a minimal proof-of-concept that creates an `RTCPeerConnection` on tvOS.

### FR-2: WebRTC Session Establishment

**Priority**: High (blocked by FR-1 go decision)

- **FR-2.1**: System shall use the SIP session details from Ring's live view API to establish a WebRTC peer connection.
- **FR-2.2**: System shall handle SIP signaling over TLS to the Ring media server (SIP INVITE with SDP offer, handle 200 OK with SDP answer).
- **FR-2.3**: System shall support ICE candidate exchange required for WebRTC connectivity.
- **FR-2.4**: System shall handle session timeouts (default 10 minutes per Ring's `expires_in`).

### FR-3: Video Rendering

**Priority**: High

- **FR-3.1**: System shall render the incoming WebRTC video track in a full-screen player view using `RTCMTLVideoView` (Metal-backed renderer).
- **FR-3.2**: System shall display the device name overlay during playback.
- **FR-3.3**: System shall provide a loading state while the WebRTC connection is being established.
- **FR-3.4**: Video quality shall adapt based on available bandwidth (WebRTC handles this natively via adaptive bitrate).

### FR-4: Stream Lifecycle

**Priority**: High

- **FR-4.1**: System shall automatically end the stream when the session expires.
- **FR-4.2**: System shall provide a retry option if the stream fails to connect.
- **FR-4.3**: System shall cleanly tear down the WebRTC connection when the user navigates away.
- **FR-4.4**: System shall handle network interruptions with appropriate error messaging and reconnection option.

### FR-5: Fallback Behavior

**Priority**: Medium

- **FR-5.1**: If WebRTC framework is not available at runtime, system shall display the snapshot backdrop with "not yet supported" overlay (from Camera Snapshots spec).
- **FR-5.2**: System shall still allow snapshot viewing and event history access when streaming is unavailable.

## Technical Requirements

### TR-1: WebRTC Framework

- Use Google's WebRTC framework for tvOS (or AmazonChimeSDK as alternative)
- Framework must support: SDP offer/answer, ICE candidates, video track rendering via `RTCMTLVideoView`
- Must compile for both tvOS device (arm64) and simulator

### TR-2: SIP Signaling

- Connect to Ring's SIP server at `sip_server_ip:sip_server_port` over TLS
- Send SIP INVITE with local SDP offer
- Parse SIP 200 OK for remote SDP answer
- Exchange ICE candidates via SIP INFO messages
- Handle SIP BYE for session teardown

### TR-3: Stream Session Management

- Use existing `StreamSessionResponse` model (already has all SIP fields)
- Session timeout: respect `expires_in` from API response (default 600 seconds)
- Connection timeout: 30 seconds for initial WebRTC connection establishment

## Correctness Properties

### CP-1: Resource Cleanup

- When the user navigates away from the player view, all WebRTC resources (peer connection, video track, SIP socket) must be fully released within 5 seconds.

### CP-2: Session Expiration

- The stream must be terminated before or at the `expires_in` deadline. The system must never attempt to send media after session expiration.

### CP-3: State Machine Consistency

- The `WebRTCConnectionState` must follow valid transitions only: `disconnected → connecting → connected → disconnected` or `disconnected → connecting → failed`. No other transitions are valid.

## Reference Implementations

- `ring-client-api` (TypeScript): [github.com/dgreif/ring](https://github.com/dgreif/ring) — SIP/WebRTC streaming via `werift`
- `ring-mqtt` (Node.js): [github.com/tsightler/ring-mqtt](https://github.com/tsightler/ring-mqtt) — Uses `go2rtc` for WebRTC-to-RTSP
