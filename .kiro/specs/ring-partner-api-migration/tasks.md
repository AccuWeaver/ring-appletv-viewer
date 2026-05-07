# Implementation Plan: Ring Partner API Migration

## Overview

Migrate the RingAppleTV tvOS app from Ring's private API (`api.ring.com/clients_api`) to the official Ring Partner API (`api.amazonvision.com/v1`). This involves replacing authentication (email/password → Device Code Flow with slow_down/expired handling), device discovery (grouped JSON → JSON:API with `.unknown` fallback and `isOnline` default-to-true), live streaming (SIP → WHEP with best-effort DELETE), events (with `limit=50` and descending sort), media download (consolidated video + snapshot), error handling (429 with Retry-After + exponential backoff), background refresh migration, and cleaning up all legacy code including `AppConfiguration.maxStreamDuration`. Domain model IDs change from `Int` to `String` throughout. WHEP methods live on `PartnerAPIClient` directly (no separate WHEPClient).

## Tasks

- [ ] 1. Create new Partner API data models and error types
  - [ ] 1.1 Create `PartnerAPIError` enum and `PartnerAPIErrorBody` in `RingAppleTV/Sources/Models/PartnerAPIError.swift`
    - Define cases: `unauthorized`, `forbidden`, `notFound`, `rateLimited(retryAfter: TimeInterval)`, `serverError(Int)`, `networkError(String)`, `decodingError(String)`, `authorizationPending`, `slowDown`, `expiredDeviceCode`
    - Add `userMessage` computed property returning user-friendly strings (no HTTP codes or jargon)
    - Add `PartnerAPIErrorBody` Codable struct with optional `code` and `message`
    - Conform to `Error` and `Equatable`
    - _Requirements: 7.1, 7.5_

  - [ ] 1.2 Create `DeviceCodeResponse` and `DeviceCodeInfo` in `RingAppleTV/Sources/Models/DeviceCodeResponse.swift`
    - `DeviceCodeResponse`: Codable DTO with `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in`, `interval` (snake_case CodingKeys)
    - `DeviceCodeInfo`: domain struct with `userCode`, `verificationUri`, `verificationUriComplete`, `expiresIn`, `pollingInterval`, `deviceCode`
    - _Requirements: 1.1_

  - [ ] 1.3 Create `PartnerDeviceResource` and `PartnerDeviceListResponse` in `RingAppleTV/Sources/Models/PartnerDeviceResource.swift`
    - JSON:API resource with `id` (String), `type`, nested `DeviceAttributes` (name, model, firmwareVersion, powerSource, optional status — with snake_case CodingKeys)
    - `toDomain()` method mapping to `RingDevice`: use `DeviceType(rawValue:) ?? .unknown` for model, default `isOnline` to `true` when `status` is absent
    - `PartnerDeviceListResponse` wrapping `data: [PartnerDeviceResource]`
    - _Requirements: 2.2, 2.3, 2.6, 2.7, 2.8, 9.1, 9.2_

  - [ ] 1.4 Create `PartnerEventResource` in `RingAppleTV/Sources/Models/PartnerEventResource.swift`
    - Codable DTO with `id` (String), `deviceId`, `type`, `createdAt` (ISO 8601), optional `duration` (snake_case CodingKeys)
    - `toDomain()` method mapping to `RingEvent` using `ISO8601DateFormatter`
    - _Requirements: 5.2, 5.3, 9.3_

  - [ ] 1.5 Create `WHEPSessionResponse` in `RingAppleTV/Sources/Models/WHEPSessionResponse.swift`
    - Struct with `sdpAnswer: String` and `sessionURL: URL`
    - Not Codable — parsed manually from HTTP 201 response body + `Location` header
    - _Requirements: 3.2, 3.3_

  - [ ] 1.6 Create `PowerSource` enum in `RingAppleTV/Sources/Models/PowerSource.swift`
    - Cases: `battery`, `line` (raw String, Codable)
    - `sessionDurationLimit` computed property: 30s for battery, 60s for line
    - _Requirements: 2.6, 3.4_

  - [ ]* 1.7 Write property test for PartnerAPIError user messages
    - **Property 10: PartnerAPIError User Messages**
    - For any `PartnerAPIError` case with random associated values, `userMessage` returns a non-empty String without HTTP codes or stack traces
    - **Validates: Requirements 7.5**

  - [ ]* 1.8 Write property test for HTTP error status mapping
    - **Property 9: HTTP Error Status Mapping**
    - For any HTTP status code 400–599, the mapping function produces the correct `PartnerAPIError` case (401→unauthorized, 403→forbidden, 404→notFound, 429→rateLimited, 5xx→serverError)
    - **Validates: Requirements 2.5, 3.7, 4.3, 4.6, 5.4, 7.1**

- [ ] 2. Update domain models (`Int` → `String` IDs, new fields)
  - [ ] 2.1 Update `RingDevice` in `RingAppleTV/Sources/Models/RingDevice.swift`
    - Change `id` from `Int` to `String`
    - Rename `description` to `name`
    - Add `model: String` property
    - Add `powerSource: PowerSource` property
    - Add `isOnline: Bool` property (default `true`)
    - Add `.unknown` case to `DeviceType` enum as fallback for unrecognized Partner API model strings
    - Remove `address`, `batteryLife`, `features` (not in Partner API)
    - Keep `deviceType`, `firmwareVersion`
    - _Requirements: 9.1, 9.2, 9.6, 2.3, 2.7, 2.8_

  - [ ] 2.2 Update `RingEvent` in `RingAppleTV/Sources/Models/RingEvent.swift`
    - Change `id` from `Int` to `String`
    - Change `deviceId` from `Int` to `String`
    - Remove `deviceName`, `thumbnailURL`, `videoAvailable` (not in Partner API)
    - Keep `eventType`, `createdAt`, `duration`
    - _Requirements: 9.3, 5.2, 5.3_

  - [ ] 2.3 Update `StreamSession` in `RingAppleTV/Sources/Models/StreamSession.swift`
    - Change `deviceId` from `Int` to `String`
    - Remove `sipServerIp`, `sipServerPort`, `sipSessionId`, `protocol_`, `isSipSession`
    - Add `sessionURL: URL` (WHEP session resource URL)
    - Add `powerSource: PowerSource`
    - Derive `maxDuration` from `powerSource.sessionDurationLimit`
    - Keep `createdAt`, `isValid`, `remainingTime`
    - _Requirements: 9.4, 3.3, 3.4_

  - [ ] 2.4 Update `AuthToken` in `RingAppleTV/Sources/Models/AuthToken.swift`
    - Add optional `clientId: String?` property
    - Change `needsRefresh` threshold from 300s (5 min) to 60s
    - Keep `accessToken`, `refreshToken`, `expiresAt`, `scope`, `tokenType`, `isExpired`
    - _Requirements: 9.5, 1.5, 1.6_

  - [ ] 2.5 Update `AppConfiguration` in `RingAppleTV/Sources/Models/AppConfiguration.swift`
    - Remove `maxStreamDuration` property (stream duration now derived from `PowerSource`)
    - Remove from `init`, `CodingKeys`, and `init(from decoder:)`
    - _Requirements: 8.12_

  - [ ] 2.6 Update `Constants.API` in `RingAppleTV/Sources/Utilities/Constants.swift`
    - Set `oauthBaseURL = "https://oauth.ring.com"`
    - Set `partnerAPIBaseURL = "https://api.amazonvision.com/v1"`
    - Remove all `clients_api`, `doorbots`, and private API endpoint constants
    - _Requirements: 8.11_

  - [ ]* 2.7 Write property test for token refresh threshold
    - **Property 2: Proactive Refresh Threshold**
    - For any `AuthToken` with arbitrary `expiresAt`, `needsRefresh` returns true iff `now >= expiresAt - 60`, and `isExpired` returns true iff `now >= expiresAt`
    - **Validates: Requirements 1.6**

  - [ ]* 2.8 Write property test for device resource JSON:API round-trip with fallbacks
    - **Property 5: Device Resource JSON:API Round-Trip with Fallbacks**
    - For any valid `PartnerDeviceResource`, encode to JSON and decode back → equivalent resource. `toDomain()` produces a `RingDevice` with matching `id`, `name`, `model`, `powerSource`. When `model` doesn't match any `DeviceType` raw value, `deviceType` is `.unknown`. When `status` is absent, `isOnline` defaults to `true`.
    - **Validates: Requirements 2.2, 2.3, 2.6, 2.7, 2.8, 9.1, 9.2, 9.6**

  - [ ]* 2.9 Write property test for event resource round-trip
    - **Property 6: Event Resource Round-Trip**
    - For any valid `PartnerEventResource`, encode to JSON and decode back → equivalent resource. `toDomain()` produces a `RingEvent` with matching `id`, `deviceId`, `eventType`, `duration`
    - **Validates: Requirements 5.2, 5.3, 9.3**

- [ ] 3. Checkpoint — Verify models compile and property tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Create `PartnerAPIClient` with WHEP methods and retry logic
  - [ ] 4.1 Create `PartnerAPIClientProtocol` in `RingAppleTV/Sources/Services/Protocols/PartnerAPIClientProtocol.swift`
    - Define methods: `requestDeviceCode`, `pollForToken`, `refreshToken`, `fetchDevices`, `fetchEvents`, `downloadVideo`, `downloadSnapshot`, `createWHEPSession`, `deleteWHEPSession`
    - WHEP methods are on this protocol directly (no separate WHEPClient)
    - All methods are `async throws`, protocol is `Sendable`
    - _Requirements: 1.1, 1.3, 2.1, 3.1, 4.1, 4.4, 5.1, 7.1_

  - [ ] 4.2 Create `PartnerAPIClient` implementation in `RingAppleTV/Sources/Services/Implementations/PartnerAPIClient.swift`
    - Base URLs: auth at `https://oauth.ring.com`, API at `https://api.amazonvision.com/v1`
    - Accept `URLSession` in init for testability
    - Implement `mapStatusCode` function mapping HTTP 4xx/5xx to `PartnerAPIError` cases
    - On 429: extract `Retry-After` header if present; if absent, use exponential backoff starting at 1s (1s → 2s → 4s). Maximum 3 retries.
    - On 401 (non-auth endpoints): attempt one token refresh before failing
    - Bearer token injection on all API requests via `Authorization` header
    - No client-side rate limiter — just handle 429 with retry
    - WHEP session creation: POST to `/devices/{deviceId}/media/streaming/whep/sessions` with `Content-Type: application/sdp`, parse SDP answer from body and session URL from `Location` header
    - WHEP session deletion: DELETE to session URL (best-effort — caller handles failure)
    - _Requirements: 1.8, 2.1, 2.5, 3.1, 3.2, 3.3, 4.1, 4.4, 5.1, 7.1, 7.2, 7.3, 7.6_

  - [ ]* 4.3 Write property test for Bearer token header injection
    - **Property 3: Bearer Token Header Injection**
    - For any non-empty access token and any API endpoint path, the constructed `URLRequest` contains `Authorization: "Bearer {token}"`
    - **Validates: Requirements 1.8**

  - [ ]* 4.4 Write property test for WHEP session round-trip
    - **Property 8: WHEP Session Round-Trip**
    - For any device ID and SDP offer string, the WHEP request has method POST, correct URL, `Content-Type: application/sdp`, and body equal to the SDP offer. For any valid SDP answer and session URL in an HTTP 201 response, the parser extracts the exact SDP answer and session URL.
    - **Validates: Requirements 3.1, 3.2, 3.3, 9.4**

- [ ] 5. Create `AuthService` (Device Code Flow with polling edge cases)
  - [ ] 5.1 Update `AuthServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/AuthServiceProtocol.swift`
    - Remove `login(email:password:)` and `login(email:password:twoFactorCode:)` methods
    - Add `startDeviceCodeFlow() async throws -> DeviceCodeInfo`
    - Add `pollForAuthorization(deviceCode: String) async throws -> AuthToken`
    - Keep `getValidToken()`, `logout()`, `isAuthenticated`
    - Add `Sendable` conformance
    - _Requirements: 1.1, 1.3, 1.5, 1.9_

  - [ ] 5.2 Rewrite `DefaultAuthService` in `RingAppleTV/Sources/Services/Implementations/DefaultAuthService.swift`
    - Inject `PartnerAPIClient` and `KeychainService` (replace `RingAPIClient` dependency)
    - `startDeviceCodeFlow()`: call `partnerAPIClient.requestDeviceCode(clientId:)`, return `DeviceCodeInfo`
    - `pollForAuthorization()`: call `partnerAPIClient.pollForToken(...)`, store tokens in Keychain, return `AuthToken`
    - `getValidToken()`: check `needsRefresh` (60s threshold), proactively refresh if needed
    - `logout()`: clear Keychain tokens and in-memory cache
    - Handle `.authorizationPending` (continue polling at current interval)
    - Handle `.slowDown` (increase polling interval by 5 seconds before next attempt)
    - Handle `.expiredDeviceCode` (propagate error, prompt user to restart)
    - On refresh 401: clear all tokens, transition to unauthenticated
    - _Requirements: 1.1, 1.3, 1.4, 1.5, 1.6, 1.7, 1.9, 1.11, 1.12_

  - [ ]* 5.3 Write property test for token Keychain round-trip
    - **Property 1: Token Keychain Round-Trip**
    - For any valid `AuthToken` (with arbitrary accessToken, refreshToken, expiresAt, scope, tokenType, clientId), storing in Keychain and retrieving produces an equal `AuthToken`
    - **Validates: Requirements 1.4, 1.5, 9.5**

  - [ ]* 5.4 Write property test for logout clearing all token state
    - **Property 4: Logout Clears All Token State**
    - For any initial token state, after `logout()`, `isAuthenticated` is false and Keychain retrieval returns nil
    - **Validates: Requirements 1.9**

  - [ ]* 5.5 Write property test for slow-down polling interval increase
    - **Property 11: Slow-Down Polling Interval Increase**
    - For any current polling interval (positive TimeInterval), when the authorization server returns a `slow_down` error, the next polling interval is exactly `currentInterval + 5` seconds
    - **Validates: Requirements 1.11**

  - [ ]* 5.6 Write unit tests for auth error handling
    - Test 401 on refresh → tokens cleared, `isAuthenticated` false
    - Test `.authorizationPending` → polling continues at current interval
    - Test `.slowDown` → interval increases by 5s
    - Test `.expiredDeviceCode` → error propagated, user prompted to restart
    - _Requirements: 1.7, 1.11, 1.12_

- [ ] 6. Checkpoint — Verify auth flow compiles and tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 7. Update `DeviceService` for JSON:API parsing with fallbacks
  - [ ] 7.1 Update `DeviceServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/DeviceServiceProtocol.swift`
    - No signature changes needed (already returns `[RingDevice]`)
    - Ensure `Sendable` conformance
    - _Requirements: 2.1_

  - [ ] 7.2 Rewrite `DefaultDeviceService` in `RingAppleTV/Sources/Services/Implementations/DefaultDeviceService.swift`
    - Inject `PartnerAPIClient` instead of `RingAPIClient`
    - Inject `AuthService` for token retrieval
    - `fetchDevices()`: call `partnerAPIClient.fetchDevices(token:)`, map `PartnerDeviceResource` → `RingDevice` via `toDomain()`
    - `toDomain()` uses `DeviceType(rawValue:) ?? .unknown` for unrecognized model strings
    - `toDomain()` defaults `isOnline` to `true` when `status` attribute is absent
    - Handle empty `data` array → return empty list, no error
    - Map HTTP errors to `PartnerAPIError`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8_

  - [ ]* 7.3 Write unit tests for device service
    - Test empty device list returns empty array
    - Test JSON:API response with multiple devices parses correctly
    - Test unrecognized model string maps to `.unknown` DeviceType
    - Test absent `status` defaults `isOnline` to `true`
    - Test HTTP error propagation
    - _Requirements: 2.4, 2.5, 2.7, 2.8_

- [ ] 8. Update `EventService` for Partner API events with pagination
  - [ ] 8.1 Update `EventServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/EventServiceProtocol.swift`
    - Change `fetchEvents(for deviceId: Int?)` to `fetchEvents(for deviceId: String?)`
    - Keep `fetchEventVideoURL(for event: RingEvent)`
    - Add `Sendable` conformance
    - _Requirements: 5.1_

  - [ ] 8.2 Rewrite `DefaultEventService` in `RingAppleTV/Sources/Services/Implementations/DefaultEventService.swift`
    - Inject `PartnerAPIClient` instead of `RingAPIClient`
    - `fetchEvents()`: call `partnerAPIClient.fetchEvents(deviceId:token:limit:)` with `limit=50`
    - Sort events descending by `createdAt`
    - Enforce client-side cap of 50 events as safety measure
    - Map `PartnerEventResource` → `RingEvent` via `toDomain()`
    - `fetchEventVideoURL()`: call `partnerAPIClient.downloadVideo(deviceId:eventId:token:)`
    - Map HTTP errors to `PartnerAPIError`
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

  - [ ]* 8.3 Write property test for event sorting and capping
    - **Property 7: Event Sorting and Capping**
    - For any list of `RingEvent` objects (arbitrary length, arbitrary `createdAt` dates), after sort-and-cap logic, result is sorted descending by `createdAt` and contains at most 50 events
    - **Validates: Requirements 5.5**

  - [ ]* 8.4 Write unit tests for event service
    - Test event list parsing with ISO 8601 dates
    - Test `limit=50` is passed in the request
    - Test descending sort order by `createdAt`
    - Test video URL extraction
    - Test HTTP error propagation
    - _Requirements: 5.2, 5.5, 5.6_

- [ ] 9. Create `MediaService` (consolidate video + snapshot)
  - [ ] 9.1 Create `MediaServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/MediaServiceProtocol.swift`
    - `downloadVideo(deviceId: String, eventId: String) async throws -> URL`
    - `downloadSnapshot(deviceId: String) async throws -> Data`
    - Conform to `Sendable`
    - _Requirements: 4.1, 4.4_

  - [ ] 9.2 Create `DefaultMediaService` in `RingAppleTV/Sources/Services/Implementations/DefaultMediaService.swift`
    - Inject `PartnerAPIClient` and `AuthService`
    - `downloadVideo()`: POST to `/devices/{deviceId}/media/video/download` via `partnerAPIClient.downloadVideo(deviceId:eventId:token:)`
    - `downloadSnapshot()`: POST to `/devices/{deviceId}/media/image/download` via `partnerAPIClient.downloadSnapshot(deviceId:token:)`
    - Map HTTP 404 to `PartnerAPIError.notFound` for events without video
    - Map other HTTP errors to `PartnerAPIError`
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6_

  - [ ]* 9.3 Write unit tests for media service
    - Test video download returns URL
    - Test snapshot download returns raw image data
    - Test 404 error for events without video maps to `.notFound`
    - _Requirements: 4.2, 4.3, 4.5_

- [ ] 10. Create `StreamSessionManager` (WHEP + WebRTC lifecycle)
  - [ ] 10.1 Create `StreamSessionManagerProtocol` in `RingAppleTV/Sources/Services/Protocols/StreamSessionManagerProtocol.swift`
    - `startStream(deviceId: String, powerSource: PowerSource) async throws`
    - `stopStream() async`
    - `connectionState: WebRTCConnectionState` (published)
    - `connectionStatePublisher: Published<WebRTCConnectionState>.Publisher`
    - Conform to `AnyObject, Sendable`
    - _Requirements: 3.1, 3.5, 3.6_

  - [ ] 10.2 Create `StreamSessionManager` implementation in `RingAppleTV/Sources/Services/Implementations/StreamSessionManager.swift`
    - Inject `PartnerAPIClient` and `AuthService` (WHEP calls go through PartnerAPIClient directly)
    - `startStream()`: create `RTCPeerConnection` (receive-only, no local tracks), generate SDP offer, call `partnerAPIClient.createWHEPSession(...)`, apply SDP answer as remote description, wait for ICE connected, start session timer based on `powerSource.sessionDurationLimit`
    - `stopStream()`: send DELETE via `partnerAPIClient.deleteWHEPSession(...)`, close `RTCPeerConnection`, cancel timer
    - On timer expiry: auto-stop stream
    - On ICE failure: transition to `.failed`, best-effort DELETE
    - On DELETE failure: log error, still close local `RTCPeerConnection` (best-effort cleanup)
    - Conditionally compiled behind `#if canImport(WebRTC)`
    - _Requirements: 3.1, 3.2, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9_

  - [ ]* 10.3 Write unit tests for stream session manager
    - Test session timer starts on ICE connected with correct duration (30s battery / 60s line)
    - Test manual stop sends DELETE and closes connection
    - Test receive-only mode (no local senders have tracks)
    - Test DELETE failure still closes local `RTCPeerConnection`
    - _Requirements: 3.4, 3.6, 3.8, 3.9_

- [ ] 11. Checkpoint — Verify all services compile and tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 12. Update ViewModels for new service interfaces
  - [ ] 12.1 Rewrite `AuthViewModel` in `RingAppleTV/Sources/ViewModels/AuthViewModel.swift`
    - Remove `email`, `password`, `twoFactorCode`, `requiresTwoFactor`, `twoFactorMethod` properties
    - Add `deviceCodeInfo: DeviceCodeInfo?` published property for displaying user code and verification URL
    - Add `isPolling: Bool` published property
    - Replace `login()` with `startLinking()` (calls `authService.startDeviceCodeFlow()`) and `pollForAuth()` (calls `authService.pollForAuthorization(deviceCode:)` in a loop)
    - Handle `expiredDeviceCode` by prompting user to restart
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - Keep `logout()`, `checkExistingAuth()`
    - _Requirements: 1.1, 1.2, 1.9, 1.12_

  - [ ] 12.2 Rewrite `PlayerViewModel` in `RingAppleTV/Sources/ViewModels/PlayerViewModel.swift`
    - Replace `VideoService` + `WebRTCStreamService?` dependencies with `StreamSessionManager`
    - Change `lastDeviceId` from `Int?` to `String?`
    - Replace `requestStream(for deviceId: Int)` with `requestStream(for deviceId: String, powerSource: PowerSource)`
    - Remove `startWebRTCStream(session:)` and `currentSessionResponse` (SIP-specific)
    - Call `streamSessionManager.startStream(deviceId:powerSource:)` directly
    - Subscribe to `streamSessionManager.connectionStatePublisher`
    - `stopStream()`: call `streamSessionManager.stopStream()`
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - _Requirements: 3.1, 3.6, 3.4_

  - [ ] 12.3 Update `DashboardViewModel` in `RingAppleTV/Sources/ViewModels/DashboardViewModel.swift`
    - Change `snapshots` dictionary key from `Int` to `String` (`[String: Data]`)
    - Update `loadSnapshots` and `fetchAllSnapshots` to use `String` device IDs
    - Replace `SnapshotService` dependency with `MediaService` for snapshot fetching
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - _Requirements: 4.4, 9.1_

  - [ ] 12.4 Update `EventsViewModel` in `RingAppleTV/Sources/ViewModels/EventsViewModel.swift`
    - Update `fetchEvents` calls to pass `String?` device ID
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - _Requirements: 5.1, 9.3_

- [ ] 13. Update `ServiceContainer` and `BackgroundRefreshManager` wiring
  - [ ] 13.1 Update `ServiceContainer` in `RingAppleTV/Sources/App/ServiceContainer.swift`
    - Remove `RingAPIClient` / `DefaultRingAPIClient` references
    - Create `PartnerAPIClient` as the infrastructure client
    - Wire `DefaultAuthService` with `PartnerAPIClient` + `KeychainService`
    - Wire `DefaultDeviceService` with `PartnerAPIClient` + `AuthService` + `CacheService`
    - Wire `DefaultEventService` with `PartnerAPIClient` + `AuthService`
    - Create `DefaultMediaService` with `PartnerAPIClient` + `AuthService`
    - Replace `VideoService` + `SnapshotService` with `MediaService`
    - Create `StreamSessionManager` (conditionally, behind `#if canImport(WebRTC)`) with `PartnerAPIClient` + `AuthService`
    - Replace `WebRTCStreamService?` with `StreamSessionManager?`
    - Wire `BackgroundRefreshManager` with `DeviceService` + `MediaService` (replacing `SnapshotService`)
    - Update `makePlayerViewModel()` to inject `StreamSessionManager`
    - Update `DashboardViewModel` init to use `MediaService` instead of `SnapshotService`
    - _Requirements: 1.1, 2.1, 3.1, 4.1, 4.4, 5.1, 10.1, 10.2_

  - [ ] 13.2 Update `BackgroundRefreshManager` in `RingAppleTV/Sources/App/BackgroundRefreshManager.swift`
    - Replace `snapshotService: SnapshotService` dependency with `mediaService: MediaService`
    - Update `handleBackgroundRefresh` to call `mediaService.downloadSnapshot(deviceId:)` with `String` device IDs
    - Preserve 10-device cap (`maxDevicesPerRefresh = 10`)
    - Preserve silent-skip-on-failure behavior for individual snapshot downloads
    - Preserve 15-minute refresh interval scheduling
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_

  - [ ]* 13.3 Write property test for background refresh invariants
    - **Property 12: Background Refresh Invariants**
    - For any list of devices (arbitrary length) and any pattern of individual snapshot download failures, the `BackgroundRefreshManager` requests snapshots for at most `min(deviceCount, 10)` devices and continues processing remaining devices when individual downloads fail
    - **Validates: Requirements 10.4, 10.5**

  - [ ]* 13.4 Write unit tests for background refresh migration
    - Test BackgroundRefreshManager calls `DeviceService` and `MediaService` with String IDs
    - Test 10-device cap is enforced
    - Test individual snapshot failure doesn't abort remaining devices
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_

- [ ] 14. Update Views for new auth flow and String IDs
  - [ ] 14.1 Update authentication views in `RingAppleTV/Sources/Views/Authentication/`
    - Replace email/password login form with Device Code Flow UI
    - Display `userCode` and `verificationUri` (or QR code encoding `verificationUriComplete`)
    - Show polling state ("Waiting for authorization...")
    - Handle `expiredDeviceCode` by prompting restart
    - _Requirements: 1.1, 1.2, 1.12_

  - [ ] 14.2 Update dashboard and player views for `String` device IDs
    - Update any view code that passes `Int` device IDs to use `String`
    - Update player view to pass `powerSource` alongside `deviceId` when starting a stream
    - Update snapshot image keying from `Int` to `String`
    - _Requirements: 9.1, 3.4_

  - [ ] 14.3 Update event views for `String` event/device IDs
    - Update any view code that passes `Int` event or device IDs to use `String`
    - _Requirements: 9.3_

- [ ] 15. Checkpoint — Verify full app compiles and all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 16. Delete legacy code and private API artifacts
  - [ ] 16.1 Delete SIP signaling code
    - Delete `RingAppleTV/Sources/Services/Implementations/SIPSignalingClient.swift`
    - Delete `SIPError` enum (defined in SIPSignalingClient.swift)
    - _Requirements: 8.3_

  - [ ] 16.2 Delete legacy API client and protocol
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultRingAPIClient.swift` (including `DevicesWrapper` and `VideoURLWrapper`)
    - Delete `RingAppleTV/Sources/Services/Protocols/RingAPIClientProtocol.swift`
    - _Requirements: 8.1, 8.2, 8.4_

  - [ ] 16.3 Delete legacy DTOs and response models
    - Delete `RingAppleTV/Sources/Models/RingDeviceResponse.swift`
    - Delete `RingAppleTV/Sources/Models/RingEventResponse.swift`
    - Delete `RingAppleTV/Sources/Models/StreamSessionResponse.swift`
    - Delete `RingAppleTV/Sources/Models/AuthTokenResponse.swift` (replaced by Partner API token response handling in `PartnerAPIClient`)
    - Delete `RingAppleTV/Sources/Models/RingAPIError.swift` (including `TwoFactorMethod` enum)
    - _Requirements: 8.4, 8.5, 8.6, 8.7, 8.8_

  - [ ] 16.4 Delete legacy service implementations and protocols
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultVideoService.swift`
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultSnapshotService.swift`
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultWebRTCStreamService.swift`
    - Delete `RingAppleTV/Sources/Services/Protocols/VideoServiceProtocol.swift`
    - Delete `RingAppleTV/Sources/Services/Protocols/SnapshotServiceProtocol.swift`
    - Delete `RingAppleTV/Sources/Services/Protocols/WebRTCStreamServiceProtocol.swift` (replaced by `StreamSessionManagerProtocol`)
    - _Requirements: 8.3, 8.9, 8.10_

  - [ ] 16.5 Remove all remaining references to private API constants
    - Search for and remove any references to `api.ring.com`, `clients_api`, `ring_official_ios`, `doorbots`, `stickup_cams`
    - Verify `Constants.API` only contains Partner API URLs
    - _Requirements: 8.1, 8.2, 8.11_

- [ ] 17. Fix compilation errors from deletions
  - Resolve any remaining compile errors caused by deleted types, changed IDs, or removed protocols
  - Ensure all `import` statements and type references are updated throughout the codebase
  - Verify `WebRTCConnectionState` is moved to or retained in `StreamSessionManagerProtocol.swift` (or a shared file) since `WebRTCStreamServiceProtocol.swift` is deleted
  - _Requirements: 8.3, 8.9_

- [ ] 18. Final checkpoint — Full build and test verification
  - Ensure all tests pass, ask the user if questions arise.
  - Verify no references to `api.ring.com`, `clients_api`, `ring_official_ios`, `SIPSignalingClient`, `SIPError`, `DevicesWrapper`, `RingDeviceResponse`, `RingEventResponse`, `StreamSessionResponse`, `RingAPIError`, `TwoFactorMethod`, or `maxStreamDuration` remain in the codebase

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements (Reqs 1–10) for traceability
- Checkpoints ensure incremental validation
- Property tests validate the 12 universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- Requirement 6 (Webhooks) is deferred — tvOS cannot host an HTTP server. The design uses polling-based event refresh instead. No webhook tasks are included.
- The WebRTC.xcframework is provided by a separate spec (WebRTC tvOS fork) and is assumed available via `#if canImport(WebRTC)`
- `WebRTCConnectionState` enum (currently in `WebRTCStreamServiceProtocol.swift`) must be preserved when that file is deleted — move it to `StreamSessionManagerProtocol.swift` or a shared types file
- WHEP methods live on `PartnerAPIClient` directly — there is no separate `WHEPClient` component
- No client-side rate limiter — 429 responses are handled with `Retry-After` header extraction and exponential backoff (1s → 2s → 4s)
- `AppConfiguration.maxStreamDuration` is removed; stream duration is derived from `PowerSource` (30s battery / 60s line-powered)
- `BackgroundRefreshManager` is updated in-place (not replaced) to use `DeviceService` (String IDs) and `MediaService` (replaces `SnapshotService`)
