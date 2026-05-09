## Part 4 of 5 — tvOS app migration

Major refactor of the tvOS app across three inter-related changes.

### 1. API migration: RingAPIClient → PartnerAPIClient
- Replaces the Ring API client, error type, and DTOs with Partner API equivalents (`PartnerAPIClient`, `PartnerAPIError`, `PartnerDeviceResource`, `PartnerEventResource`, `PowerSource`).
- Consolidates `VideoService` + `SnapshotService` into a single `MediaService` with `downloadVideo` and `downloadSnapshot`.
- Updates Device, Event, and Dashboard view models and views for the new resource shape (`RingDevice.id` becomes String, `powerSource` required).
- Removes obsolete `RateLimitManager` and `RetryStrategy` utilities.

### 2. Backend-mediated auth
- `BackendAuthService` fetches tokens from the partner-auth backend via `GET /api/token` with Bearer API key.
- `MockAuthService` returns a dummy token for local-dev / simulator runs when `AppConfiguration.useMocks` is true.
- `LoginView` shows setup instructions directing the user to authorize in the Ring app; `AuthViewModel` polls the backend for the resulting token.
- `AppConfiguration` gains `authBackendBaseURL`, `authBackendAPIKey`, `authBackendUserId`.

### 3. WebRTC live streaming via WHEP
- `NoOpAudioDevice` stubs `RTCAudioDevice` to bypass the iOS ADM init crash on tvOS (root cause of the `RTCPeerConnectionFactory` assertion).
- `StreamSessionManager` runs the WHEP offer/answer exchange with SDP answer munging for `rtcp-mux` and m-line ordering (mediamtx workaround).
- Unified Plan: extracts the remote video track via `didAddReceiver`.
- `RingAppleTVApp` calls `RTCInitializeSSL()` once at launch.
- `HLSPlayerView` wraps `AVPlayerLayer` as a simulator fallback (WebRTC video decode does not render through `RTCMTLVideoView` in the tvOS simulator even though the connection succeeds).
- `WebRTC.xcframework` is linked via `Package.swift` and `project.pbxproj`.

### Tests
**New:** `BackendAuthServiceTests`, `PlayerViewModelWebRTCTests`, `WebRTCPropertyTests`, `MockURLProtocol`, `MockPartnerAPIClient`, `MockMediaService`, `MockStreamSessionManager`, `MockAuthService`.
**Removed:** `RingAPIClientTests`, `VideoServiceTests`, `DefaultSnapshotServiceTests`, `NetworkingUtilitiesTests`, `SnapshotPropertyTests`, `RetryPropertyTests`, `MockRingAPIClient`, `MockSnapshotService`, `MockVideoService`.

### Verified
- Real Apple TV HD (AppleTV5,3 A8 chip) — WebRTC connects and plays live video.
- tvOS simulator — full UI flow via HLS fallback.

### Dependencies
- Requires **PR #1**, **PR #2**, and **PR #3** to be merged first.

### PR stack position: 4 of 5
`main ← 1 ← 2 ← 3 ← **4** ← 5`
