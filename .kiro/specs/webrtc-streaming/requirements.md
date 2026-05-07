# WebRTC Live Streaming — Requirements

**Feature Name**: WebRTC Live Streaming
**Version**: 2.0
**Last Updated**: April 2026
**Depends On**: Camera Snapshots spec (COMPLETE)

## Overview

Enable live video and audio streaming from Ring cameras on Apple TV using WebRTC. Ring's API uses SIP signaling over TLS to establish WebRTC media sessions. This spec covers the WebRTC framework integration, SIP signaling client, video/audio rendering, and stream lifecycle management.

This is a high-risk feature due to tvOS not including a native WebRTC framework. A framework spike (Requirement 1) must be completed with a go/no-go decision before proceeding with the remaining implementation.

## Research Summary

1. **Live Stream Protocol**: Ring uses SIP signaling over TLS to establish a WebRTC media session. The POST to `/clients_api/doorbots/{id}/live_view` returns SIP connection details. The client must establish a WebRTC peer connection using these SIP parameters.

2. **Stream Session Response Fields** (already implemented in `StreamSessionResponse`):
   - `sipServerIp` / `sipServerPort` / `sipServerTls`: SIP server endpoint and TLS flag.
   - `sipSessionId`: Unique session identifier for SIP INVITE headers.
   - `sipFrom`: SIP URI for the client (caller) — used as `From` header.
   - `sipTo`: SIP URI for the Ring device (callee) — used as `To` header.
   - `sipToken`: Auth token for the SIP session.
   - `sipEndpoints`: Array of SIP endpoint URIs (may include STUN/TURN addresses).
   - `doorbotId`: Ring device ID.
   - `expiresIn`: Session TTL in seconds (default 600).
   - `protocol_`: Always "sip" for live streams.

3. **Reference Implementations**:
   - `ring-client-api` (TypeScript): Uses `werift` for WebRTC via SIP, pipes RTP to `ffmpeg`/`go2rtc`.
   - `ring-mqtt` (Node.js): Uses `go2rtc` for WebRTC-to-RTSP conversion.

4. **tvOS Constraints**: No native WebRTC framework. Options:
   - **Option A (preferred)**: Google's `WebRTC.framework` compiled for tvOS from source.
   - **Option B**: `AmazonChimeSDK` which wraps WebRTC.
   - **Option C (fallback)**: Companion service (Mac/server bridges WebRTC→HLS, Apple TV consumes via AVPlayer).

5. **Audio**: Ring cameras transmit audio alongside video in the WebRTC media stream. The Apple TV outputs audio through HDMI/HomePod/Bluetooth — standard audio playback works without special APIs.

6. **Existing Implementation**:
   - Camera snapshots display on dashboard cards and as player backdrop (complete).
   - `PlayerView` shows snapshot + "not yet supported" overlay for SIP sessions. WebRTC replaces this with live video.
   - `PlayerViewModel` already handles `requestStream(for:)` → `StreamSession`. WebRTC extends it with connection state.
   - `StreamSessionResponse` already decodes all SIP fields.

## Functional Requirements

### FR-1: WebRTC Framework Spike (go/no-go gate)

**Priority**: Critical

- **FR-1.1**: Evaluate whether Google's WebRTC framework compiles for tvOS (arm64 + simulator).
- **FR-1.2**: If Google WebRTC fails, evaluate AmazonChimeSDK for tvOS.
- **FR-1.3**: If neither is viable, document the companion service fallback and pause this spec.
- **FR-1.4**: Produce a proof-of-concept that instantiates `RTCPeerConnection` on tvOS simulator.
- **FR-1.5**: Verify that `RTCMTLVideoView` (Metal-backed renderer) renders a test video track on tvOS simulator.

### FR-2: SIP Signaling

**Priority**: High (blocked by FR-1 go decision)

- **FR-2.1**: Connect to Ring's SIP server at `sipServerIp:sipServerPort` over TLS.
- **FR-2.2**: Send SIP INVITE with local SDP offer, using `sipFrom`, `sipTo`, `sipSessionId`, and `sipToken` from the session response.
- **FR-2.3**: Parse SIP 200 OK to extract remote SDP answer.
- **FR-2.4**: Exchange ICE candidates via SIP INFO messages.
- **FR-2.5**: Send SIP BYE for clean session teardown.
- **FR-2.6**: Timeout after 30 seconds if SIP connection isn't established.

### FR-3: WebRTC Session Establishment

**Priority**: High

- **FR-3.1**: Create `RTCPeerConnection`, apply local SDP offer and remote SDP answer.
- **FR-3.2**: Gather local ICE candidates and relay through SIP signaling.
- **FR-3.3**: Apply remote ICE candidates received via SIP INFO.
- **FR-3.4**: Extract video track from the first media stream when connected.
- **FR-3.5**: Extract audio track from the media stream when connected.
- **FR-3.6**: Respect `expiresIn` — terminate session at or before the deadline.
- **FR-3.7**: Timeout after 30 seconds if peer connection isn't established.

### FR-4: Video & Audio Rendering

**Priority**: High

- **FR-4.1**: Render incoming video track full-screen via `RTCMTLVideoView`, replacing the snapshot backdrop.
- **FR-4.2**: Display device name overlay during playback.
- **FR-4.3**: Show loading state (snapshot backdrop + connecting indicator) while WebRTC connects.
- **FR-4.4**: Render video at the track's native aspect ratio (aspect-fit within bounds).
- **FR-4.5**: Play incoming audio through the Apple TV's audio output (HDMI/HomePod/Bluetooth).
- **FR-4.6**: Provide a mute/unmute toggle accessible via Siri Remote.
- **FR-4.7**: Default to audio enabled (unmuted) when stream starts.
- **FR-4.8**: If no audio track is present, display video without audio and without error.

### FR-5: Stream Lifecycle

**Priority**: High

- **FR-5.1**: Auto-disconnect when session timer reaches `expiresIn`. Show "Session expired" with restart option.
- **FR-5.2**: Disconnect and release all resources within 5 seconds when user navigates away.
- **FR-5.3**: Show error with retry button if connection fails during establishment.
- **FR-5.4**: Show "Connection lost" with reconnect option if stream drops mid-session.
- **FR-5.5**: On retry/reconnect, request a new stream session and re-establish WebRTC.
- **FR-5.6**: Follow valid state transitions only: `disconnected → connecting → connected → disconnected` or `disconnected → connecting → failed → disconnected`.

### FR-6: Fallback Behavior

**Priority**: Medium

- **FR-6.1**: If WebRTC framework unavailable at runtime, show snapshot backdrop + "not yet supported" overlay (existing behavior).
- **FR-6.2**: Snapshot viewing and event history remain accessible regardless of WebRTC availability.

## Technical Requirements

### TR-1: WebRTC Framework

- Must support: SDP offer/answer, ICE candidates, video/audio track extraction, `RTCMTLVideoView`
- Must compile for tvOS device (arm64) and simulator

### TR-2: SIP Signaling

- Use `NWConnection` (Network.framework) for TLS socket
- SIP message format per RFC 3261 (INVITE, 200 OK, INFO, BYE)
- Connection timeout: 30 seconds

### TR-3: Session Management

- Use existing `StreamSessionResponse` model (all SIP fields already decoded)
- Session timeout: respect `expiresIn` (default 600s)
- Connection timeout: 30 seconds for WebRTC establishment

### TR-4: Audio

- Use `AVAudioSession` for audio output routing
- Support system volume control via Siri Remote
- No microphone/talk-back in this spec (tvOS restricts mic access to Siri/dictation)

## Correctness Properties

### CP-1: Resource Cleanup

All WebRTC resources (peer connection, video track, audio track, SIP socket) must be fully released within 5 seconds of disconnect.

### CP-2: Session Expiration

The stream must terminate at or before the `expiresIn` deadline. No media transmission after expiration.

### CP-3: State Machine Consistency

Valid transitions: `disconnected → connecting → connected → disconnected` or `disconnected → connecting → failed → disconnected`. No other transitions permitted.

## Reference Implementations

- [ring-client-api](https://github.com/dgreif/ring) (TypeScript) — SIP/WebRTC via `werift`
- [ring-mqtt](https://github.com/tsightler/ring-mqtt) (Node.js) — `go2rtc` for WebRTC-to-RTSP
