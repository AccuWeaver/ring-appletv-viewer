# Implementation Plan: Ring Partner API Migration

## Overview

Migrate the RingAppleTV tvOS app from Ring's private API (`api.ring.com/clients_api`) to the official Ring Partner API (`api.amazonvision.com/v1`). This involves replacing authentication (email/password → Device Code Flow), device discovery (grouped JSON → JSON:API), live streaming (SIP → WHEP), events/media endpoints, error handling, and cleaning up all legacy code. Domain model IDs change from `Int` to `String` throughout.

## Tasks

- [ ] 1. Create new Partner API data models and error types
  - [ ] 1.1 Create `PartnerAPIError` enum in `RingAppleTV/Sources/Models/PartnerAPIError.swift`
    - Define cases: `unauthorized`, `forbidden`, `notFound`, `rateLimited(retryAfter: TimeInterval)`, `serverError(Int)`, `networkError(String)`, `decodingError(String)`, `authorizationPending`, `slowDown`, `expiredDeviceCode`
    - Add `userMessage` computed property returning user-friendly strings (no HTTP codes or jargon)
    - Conform to `Error` and `Equatable`
    - _Requirements: 9.1, 9.5_

  - [ ] 1.2 Create `DeviceCodeResponse` and `DeviceCodeInfo` in `RingAppleTV/Sources/Models/DeviceCodeResponse.swift`
    - `DeviceCodeResponse`: Codable DTO with `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in`, `interval` (snake_case CodingKeys)
    - `DeviceCodeInfo`: domain struct with `userCode`, `verificationUri`, `verificationUriComplete`, `expiresIn`, `pollingInterval`, `deviceCode`
    - _Requirements: 1.1_

  - [ ] 1.3 Create `PartnerDeviceResource` and `PartnerDeviceListResponse` in `RingAppleTV/Sources/Models/PartnerDeviceResource.swift`
    - JSON:API resource with `id` (String), `type`, nested `DeviceAttributes` (name, model, firmwareVersion, powerSource with snake_case CodingKeys)
    - `toDomain()` method mapping to `RingDevice`
    - `PartnerDeviceListResponse` wrapping `data: [PartnerDeviceResource]`
    - _Requirements: 2.2, 2.3, 2.6, 11.1, 11.2_

  - [ ] 1.4 Create `PartnerEventResource` in `RingAppleTV/Sources/Models/PartnerEventResource.swift`
    - Codable DTO with `id` (String), `deviceId`, `type`, `createdAt` (ISO 8601), optional `duration` (snake_case CodingKeys)
    - `toDomain()` method mapping to `RingEvent` using `ISO8601DateFormatter`
    - _Requirements: 5.2, 5.3, 11.3_

  - [ ] 1.5 Create `WHEPSessionResponse` in `RingAppleTV/Sources/Models/WHEPSessionResponse.swift`
    - Struct with `sdpAnswer: String` and `sessionURL: URL`
    - Not Codable — parsed manually from HTTP 201 response body + `Location` header
    - _Requirements: 3.2, 3.3, 4.2_

  - [ ] 1.6 Create `PowerSource` enum in `RingAppleTV/Sources/Models/PowerSource.swift`
    - Cases: `battery`, `line` (raw String, Codable)
    - `sessionDurationLimit` computed property: 30s for battery, 60s for line
    - _Requirements: 2.6, 3.4_

  - [ ] 1.7 Create `PartnerAPIErrorBody` in `RingAppleTV/Sources/Models/PartnerAPIError.swift` (append to existing file)
    - Codable struct with optional `code` and `message` for parsing error response bodies
    - _Requirements: 9.1_

  - [ ]* 1.8 Write property tests for `PartnerAPIError` user messages
    - **Property 10: PartnerAPIError User Messages**
    - For any `PartnerAPIError` case with random associated values, `userMessage` returns a non-empty String without HTTP codes or stack traces
    - **Validates: Requirements 9.5**

  - [ ]* 1.9 Write property test for HTTP error status mapping
    - **Property 9: HTTP Error Status Mapping**
    - For any HTTP status code 400–599, the mapping function produces the correct `PartnerAPIError` case (401→unauthorized, 403→forbidden, 404→notFound, 429→rateLimited, 5xx→serverError)
    - **Validates: Requirements 9.1**

- [ ] 2. Update domain models (`Int` → `String` IDs, new fields)
  - [ ] 2.1 Update `RingDevice` in `RingAppleTV/Sources/Models/RingDevice.swift`
    - Change `id` from `Int` to `String`
    - Rename `description` to `name`
    - Add `model: String` property
    - Add `powerSource: PowerSource` property
    - Remove `address`, `batteryLife`, `features` (not in Partner API)
    - Keep `deviceType`, `firmwareVersion`, `isOnline`
    - _Requirements: 11.1, 11.2, 2.3_

  - [ ] 2.2 Update `RingEvent` in `RingAppleTV/Sources/Models/RingEvent.swift`
    - Change `id` from `Int` to `String`
    - Change `deviceId` from `Int` to `String`
    - Remove `deviceName`, `thumbnailURL`, `videoAvailable` (not in Partner API)
    - Keep `eventType`, `createdAt`, `duration`
    - _Requirements: 11.3, 5.2, 5.3_

  - [ ] 2.3 Update `StreamSession` in `RingAppleTV/Sources/Models/StreamSession.swift`
    - Change `deviceId` from `Int` to `String`
    - Remove `sipServerIp`, `sipServerPort`, `sipSessionId`, `protocol_`, `isSipSession`
    - Add `sessionURL: URL` (WHEP session resource URL)
    - Add `powerSource: PowerSource`
    - Derive `maxDuration` from `powerSource.sessionDurationLimit`
    - Keep `createdAt`, `isValid`, `remainingTime`
    - _Requirements: 11.4, 4.2, 3.4_

  - [ ] 2.4 Update `AuthToken` in `RingAppleTV/Sources/Models/AuthToken.swift`
    - Add optional `clientId: String?` property
    - Change `needsRefresh` threshold from 300s (5 min) to 60s
    - Keep `accessToken`, `refreshToken`, `expiresAt`, `scope`, `tokenType`, `isExpired`
    - _Requirements: 11.5, 1.5_

  - [ ]* 2.5 Write property test for token refresh threshold
    - **Property 2: Proactive Refresh Threshold**
    - For any `AuthToken` with arbitrary `expiresAt`, `needsRefresh` returns true iff `now >= expiresAt - 60`, and `isExpired` returns true iff `now >= expiresAt`
    - **Validates: Requirements 1.5**

  - [ ]* 2.6 Write property test for device resource JSON:API round-trip
    - **Property 5: Device Resource JSON:API Round-Trip**
    - For any valid `PartnerDeviceResource`, encode to JSON and decode back → equivalent resource. `toDomain()` produces a `RingDevice` with matching `id`, `name`, `model`, `powerSource`
    - **Validates: Requirements 2.2, 2.3, 2.6, 11.1, 11.2**

  - [ ]* 2.7 Write property test for event resource round-trip
    - **Property 6: Event Resource Round-Trip**
    - For any valid `PartnerEventResource`, encode to JSON and decode back → equivalent resource. `toDomain()` produces a `RingEvent` with matching `id`, `deviceId`, `eventType`, `duration`
    - **Validates: Requirements 5.2, 5.3, 11.3**

- [ ] 3. Checkpoint — Verify models compile and property tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Create `PartnerAPIClient` and protocol
  - [ ] 4.1 Create `PartnerAPIClientProtocol` in `RingAppleTV/Sources/Services/Protocols/PartnerAPIClientProtocol.swift`
    - Define methods: `requestDeviceCode`, `pollForToken`, `refreshToken`, `fetchDevices`, `fetchEvents`, `downloadVideo`, `downloadSnapshot`, `createWHEPSession`, `deleteWHEPSession`
    - All methods are `async throws`, protocol is `Sendable`
    - _Requirements: 1.1, 1.2, 2.1, 3.1, 5.1, 6.1, 7.1_

  - [ ] 4.2 Create `PartnerAPIClient` implementation in `RingAppleTV/Sources/Services/Implementations/PartnerAPIClient.swift`
    - Base URLs: auth at `https://oauth.ring.com`, API at `https://api.amazonvision.com/v1`
    - Accept `URLSession` in init for testability
    - Implement `mapStatusCode` function mapping HTTP 4xx/5xx to `PartnerAPIError` cases
    - On 429: extract `Retry-After` header, retry up to 3 times
    - On 401 (non-auth endpoints): attempt one token refresh before failing
    - Bearer token injection on all API requests via `Authorization` header
    - WHEP session creation: POST to `/devices/{deviceId}/media/streaming/whep/sessions` with `Content-Type: application/sdp`, parse SDP answer from body and session URL from `Location` header
    - WHEP session deletion: DELETE to session URL
    - _Requirements: 1.7, 2.1, 2.5, 3.1, 3.2, 3.3, 5.1, 6.1, 7.1, 9.1, 9.2, 9.3_

  - [ ]* 4.3 Write property test for Bearer token header injection
    - **Property 3: Bearer Token Header Injection**
    - For any non-empty access token and any API endpoint path, the constructed `URLRequest` contains `Authorization: "Bearer {token}"`
    - **Validates: Requirements 1.7**

  - [ ]* 4.4 Write property test for WHEP request construction
    - **Property 8: WHEP Request Construction**
    - For any device ID and SDP offer string, the WHEP request has method POST, correct URL, `Content-Type: application/sdp`, and body equal to the SDP offer
    - **Validates: Requirements 3.1**

  - [ ]* 4.5 Write property test for WHEP response parsing
    - **Property 7: WHEP Response Parsing**
    - For any valid SDP answer and session URL, when wrapped in an HTTP 201 response, the parser extracts the exact SDP answer and session URL
    - **Validates: Requirements 3.2, 3.3**

- [ ] 5. Create `AuthService` (Device Code Flow)
  - [ ] 5.1 Update `AuthServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/AuthServiceProtocol.swift`
    - Remove `login(email:password:)` and `login(email:password:twoFactorCode:)` methods
    - Add `startDeviceCodeFlow() async throws -> DeviceCodeInfo`
    - Add `pollForAuthorization(deviceCode: String) async throws -> AuthToken`
    - Keep `getValidToken()`, `logout()`, `isAuthenticated`
    - Add `Sendable` conformance
    - _Requirements: 1.1, 1.2, 1.5, 1.8_

  - [ ] 5.2 Rewrite `DefaultAuthService` in `RingAppleTV/Sources/Services/Implementations/DefaultAuthService.swift`
    - Inject `PartnerAPIClient` and `KeychainService` (replace `RingAPIClient` dependency)
    - `startDeviceCodeFlow()`: call `partnerAPIClient.requestDeviceCode(clientId:)`, return `DeviceCodeInfo`
    - `pollForAuthorization()`: call `partnerAPIClient.pollForToken(...)`, store tokens in Keychain, return `AuthToken`
    - `getValidToken()`: check `needsRefresh` (60s threshold), proactively refresh if needed
    - `logout()`: clear Keychain tokens and in-memory cache
    - Handle `.authorizationPending` (continue polling), `.slowDown` (increase interval by 5s), `.expiredDeviceCode` (propagate)
    - On refresh 401: clear all tokens, transition to unauthenticated
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 1.6, 1.8_

  - [ ]* 5.3 Write property test for token Keychain round-trip
    - **Property 1: Token Keychain Round-Trip**
    - For any valid `AuthToken`, storing in Keychain and retrieving produces an equal `AuthToken`
    - **Validates: Requirements 1.4**

  - [ ]* 5.4 Write property test for logout clearing all token state
    - **Property 4: Logout Clears All Token State**
    - For any initial token state, after `logout()`, `isAuthenticated` is false and Keychain retrieval returns nil
    - **Validates: Requirements 1.8**

  - [ ]* 5.5 Write unit tests for auth error handling
    - Test 401 on refresh → tokens cleared, `isAuthenticated` false
    - Test `.authorizationPending` → polling continues
    - Test `.slowDown` → interval increases by 5s
    - Test `.expiredDeviceCode` → error propagated
    - _Requirements: 1.6_

- [ ] 6. Checkpoint — Verify auth flow compiles and tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 7. Update `DeviceService` for JSON:API parsing
  - [ ] 7.1 Update `DeviceServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/DeviceServiceProtocol.swift`
    - No signature changes needed (already returns `[RingDevice]`)
    - Ensure `Sendable` conformance
    - _Requirements: 2.1_

  - [ ] 7.2 Rewrite `DefaultDeviceService` in `RingAppleTV/Sources/Services/Implementations/DefaultDeviceService.swift`
    - Inject `PartnerAPIClient` instead of `RingAPIClient`
    - Inject `AuthService` for token retrieval
    - `fetchDevices()`: call `partnerAPIClient.fetchDevices(token:)`, map `PartnerDeviceResource` → `RingDevice` via `toDomain()`
    - Handle empty `data` array → return empty list, no error
    - Map HTTP errors to `PartnerAPIError`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6_

  - [ ]* 7.3 Write unit tests for device service
    - Test empty device list returns empty array
    - Test JSON:API response with multiple devices parses correctly
    - Test HTTP error propagation
    - _Requirements: 2.4, 2.5_

- [ ] 8. Update `EventService` for Partner API events
  - [ ] 8.1 Update `EventServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/EventServiceProtocol.swift`
    - Change `fetchEvents(for deviceId: Int?)` to `fetchEvents(for deviceId: String?)`
    - Keep `fetchEventVideoURL(for event: RingEvent)`
    - Add `Sendable` conformance
    - _Requirements: 5.1_

  - [ ] 8.2 Rewrite `DefaultEventService` in `RingAppleTV/Sources/Services/Implementations/DefaultEventService.swift`
    - Inject `PartnerAPIClient` instead of `RingAPIClient`
    - `fetchEvents()`: call `partnerAPIClient.fetchEvents(deviceId:token:)`, map `PartnerEventResource` → `RingEvent` via `toDomain()`
    - `fetchEventVideoURL()`: call `partnerAPIClient.downloadVideo(deviceId:eventId:token:)`
    - Map HTTP errors to `PartnerAPIError`
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 6.1, 6.2_

  - [ ]* 8.3 Write unit tests for event service
    - Test event list parsing with ISO 8601 dates
    - Test video URL extraction
    - Test HTTP error propagation
    - _Requirements: 5.2, 6.2_

- [ ] 9. Create `MediaService` (consolidate video + snapshot)
  - [ ] 9.1 Create `MediaServiceProtocol` in `RingAppleTV/Sources/Services/Protocols/MediaServiceProtocol.swift`
    - `downloadVideo(deviceId: String, eventId: String) async throws -> URL`
    - `downloadSnapshot(deviceId: String) async throws -> Data`
    - Conform to `Sendable`
    - _Requirements: 6.1, 7.1_

  - [ ] 9.2 Create `DefaultMediaService` in `RingAppleTV/Sources/Services/Implementations/DefaultMediaService.swift`
    - Inject `PartnerAPIClient` and `AuthService`
    - `downloadVideo()`: call `partnerAPIClient.downloadVideo(deviceId:eventId:token:)`
    - `downloadSnapshot()`: call `partnerAPIClient.downloadSnapshot(deviceId:token:)`
    - Map HTTP errors to `PartnerAPIError`
    - _Requirements: 6.1, 6.2, 6.3, 7.1, 7.2, 7.3_

  - [ ]* 9.3 Write unit tests for media service
    - Test video download returns URL
    - Test snapshot download returns raw data
    - Test 404 error for events without video
    - _Requirements: 6.2, 7.2_

- [ ] 10. Create `StreamSessionManager` (WHEP + WebRTC lifecycle)
  - [ ] 10.1 Create `StreamSessionManagerProtocol` in `RingAppleTV/Sources/Services/Protocols/StreamSessionManagerProtocol.swift`
    - `startStream(deviceId: String, powerSource: PowerSource) async throws`
    - `stopStream() async`
    - `connectionState: WebRTCConnectionState` (published)
    - `connectionStatePublisher: Published<WebRTCConnectionState>.Publisher`
    - Conform to `AnyObject, Sendable`
    - _Requirements: 3.1, 3.5, 3.6, 4.4_

  - [ ] 10.2 Create `StreamSessionManager` implementation in `RingAppleTV/Sources/Services/Implementations/StreamSessionManager.swift`
    - Inject `PartnerAPIClient` and `AuthService`
    - `startStream()`: create `RTCPeerConnection` (receive-only, no local tracks), generate SDP offer, call `partnerAPIClient.createWHEPSession(...)`, apply SDP answer as remote description, wait for ICE connected, start session timer based on `powerSource.sessionDurationLimit`
    - `stopStream()`: send DELETE via `partnerAPIClient.deleteWHEPSession(...)`, close `RTCPeerConnection`, cancel timer
    - On timer expiry: auto-stop stream
    - On ICE failure: transition to `.failed`, best-effort DELETE
    - On DELETE failure: log error, still close local connection
    - Conditionally compiled behind `#if canImport(WebRTC)`
    - _Requirements: 3.1, 3.2, 3.4, 3.5, 3.6, 3.7, 3.8, 4.3, 4.4_

  - [ ]* 10.3 Write unit tests for stream session manager
    - Test session timer starts on ICE connected with correct duration (30s battery / 60s line)
    - Test manual stop sends DELETE and closes connection
    - Test receive-only mode (no local senders have tracks)
    - _Requirements: 3.4, 3.6, 3.8_

- [ ] 11. Checkpoint — Verify all services compile and tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 12. Update ViewModels for new service interfaces
  - [ ] 12.1 Rewrite `AuthViewModel` in `RingAppleTV/Sources/ViewModels/AuthViewModel.swift`
    - Remove `email`, `password`, `twoFactorCode`, `requiresTwoFactor`, `twoFactorMethod` properties
    - Add `deviceCodeInfo: DeviceCodeInfo?` published property for displaying user code and verification URL
    - Add `isPolling: Bool` published property
    - Replace `login()` with `startLinking()` (calls `authService.startDeviceCodeFlow()`) and `pollForAuth()` (calls `authService.pollForAuthorization(deviceCode:)` in a loop)
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - Keep `logout()`, `checkExistingAuth()`
    - _Requirements: 1.1, 1.2, 1.8_

  - [ ] 12.2 Rewrite `PlayerViewModel` in `RingAppleTV/Sources/ViewModels/PlayerViewModel.swift`
    - Replace `VideoService` + `WebRTCStreamService?` dependencies with `StreamSessionManager`
    - Change `lastDeviceId` from `Int?` to `String?`
    - Replace `requestStream(for deviceId: Int)` with `requestStream(for deviceId: String, powerSource: PowerSource)`
    - Remove `startWebRTCStream(session:)` and `currentSessionResponse` (SIP-specific)
    - Call `streamSessionManager.startStream(deviceId:powerSource:)` directly
    - Subscribe to `streamSessionManager.connectionStatePublisher`
    - `stopStream()`: call `streamSessionManager.stopStream()`
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - _Requirements: 3.1, 3.6, 4.3, 4.4_

  - [ ] 12.3 Update `DashboardViewModel` in `RingAppleTV/Sources/ViewModels/DashboardViewModel.swift`
    - Change `snapshots` dictionary key from `Int` to `String` (`[String: Data]`)
    - Update `loadSnapshots` and `fetchAllSnapshots` to use `String` device IDs
    - Replace `SnapshotService` dependency with `MediaService` for snapshot fetching
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - _Requirements: 7.1, 11.1_

  - [ ] 12.4 Update `EventsViewModel` in `RingAppleTV/Sources/ViewModels/EventsViewModel.swift`
    - Update `fetchEvents` calls to pass `String?` device ID
    - Update error handling from `RingAPIError` to `PartnerAPIError`
    - _Requirements: 5.1, 11.3_

- [ ] 13. Update `ServiceContainer` wiring
  - Remove `RingAPIClient` / `DefaultRingAPIClient` references
  - Create `PartnerAPIClient` as the infrastructure client
  - Wire `DefaultAuthService` with `PartnerAPIClient` + `KeychainService`
  - Wire `DefaultDeviceService` with `PartnerAPIClient` + `AuthService` + `CacheService`
  - Wire `DefaultEventService` with `PartnerAPIClient` + `AuthService`
  - Create `DefaultMediaService` with `PartnerAPIClient` + `AuthService`
  - Replace `VideoService` + `SnapshotService` with `MediaService`
  - Create `StreamSessionManager` (conditionally, behind `#if canImport(WebRTC)`) with `PartnerAPIClient` + `AuthService`
  - Replace `WebRTCStreamService?` with `StreamSessionManager?`
  - Update `makePlayerViewModel()` to inject `StreamSessionManager`
  - Update `DashboardViewModel` init to use `MediaService` instead of `SnapshotService`
  - _Requirements: 1.1, 2.1, 3.1, 5.1, 6.1, 7.1_

- [ ] 14. Update Views for new auth flow and String IDs
  - [ ] 14.1 Update authentication views in `RingAppleTV/Sources/Views/Authentication/`
    - Replace email/password login form with Device Code Flow UI
    - Display `userCode` and `verificationUri` (or QR code encoding `verificationUriComplete`)
    - Show polling state ("Waiting for authorization...")
    - Handle `expiredDeviceCode` by prompting restart
    - _Requirements: 1.1_

  - [ ] 14.2 Update dashboard and player views for `String` device IDs
    - Update any view code that passes `Int` device IDs to use `String`
    - Update player view to pass `powerSource` alongside `deviceId` when starting a stream
    - Update snapshot image keying from `Int` to `String`
    - _Requirements: 11.1, 3.4_

  - [ ] 14.3 Update event views for `String` event/device IDs
    - Update any view code that passes `Int` event or device IDs to use `String`
    - _Requirements: 11.3_

- [ ] 15. Checkpoint — Verify full app compiles and all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 16. Delete legacy code and private API artifacts
  - [ ] 16.1 Delete SIP signaling code
    - Delete `RingAppleTV/Sources/Services/Implementations/SIPSignalingClient.swift`
    - Delete `SIPError` enum (defined in SIPSignalingClient.swift)
    - _Requirements: 4.1_

  - [ ] 16.2 Delete legacy API client and protocol
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultRingAPIClient.swift` (including `DevicesWrapper` and `VideoURLWrapper`)
    - Delete `RingAppleTV/Sources/Services/Protocols/RingAPIClientProtocol.swift`
    - _Requirements: 10.1, 10.2_

  - [ ] 16.3 Delete legacy DTOs and response models
    - Delete `RingAppleTV/Sources/Models/RingDeviceResponse.swift`
    - Delete `RingAppleTV/Sources/Models/RingEventResponse.swift`
    - Delete `RingAppleTV/Sources/Models/StreamSessionResponse.swift`
    - Delete `RingAppleTV/Sources/Models/AuthTokenResponse.swift` (replaced by Partner API token response handling in `PartnerAPIClient`)
    - Delete `RingAppleTV/Sources/Models/RingAPIError.swift` (including `TwoFactorMethod` enum)
    - _Requirements: 10.3, 10.4, 10.5, 10.6, 10.7_

  - [ ] 16.4 Delete legacy service implementations and protocols
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultVideoService.swift`
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultSnapshotService.swift`
    - Delete `RingAppleTV/Sources/Services/Implementations/DefaultWebRTCStreamService.swift`
    - Delete `RingAppleTV/Sources/Services/Protocols/VideoServiceProtocol.swift`
    - Delete `RingAppleTV/Sources/Services/Protocols/SnapshotServiceProtocol.swift`
    - Delete `RingAppleTV/Sources/Services/Protocols/WebRTCStreamServiceProtocol.swift` (replaced by `StreamSessionManagerProtocol`)
    - _Requirements: 4.1, 4.3, 10.1_

  - [ ] 16.5 Remove all remaining references to private API constants
    - Search for and remove any references to `api.ring.com`, `clients_api`, `ring_official_ios`, `doorbots`, `stickup_cams`
    - Update `RingAppleTV/Sources/Utilities/Constants.swift` if it contains private API URLs
    - _Requirements: 10.1, 10.2_

- [ ] 17. Fix compilation errors from deletions
  - Resolve any remaining compile errors caused by deleted types, changed IDs, or removed protocols
  - Ensure all `import` statements and type references are updated throughout the codebase
  - Verify `WebRTCConnectionState` is moved to or retained in `StreamSessionManagerProtocol.swift` (or a shared file) since `WebRTCStreamServiceProtocol.swift` is deleted
  - _Requirements: 4.1, 10.1_

- [ ] 18. Final checkpoint — Full build and test verification
  - Ensure all tests pass, ask the user if questions arise.
  - Verify no references to `api.ring.com`, `clients_api`, `ring_official_ios`, `SIPSignalingClient`, `SIPError`, `DevicesWrapper`, `RingDeviceResponse`, `RingEventResponse`, `StreamSessionResponse`, `RingAPIError`, or `TwoFactorMethod` remain in the codebase

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- Requirement 8 (Webhooks) is deferred — tvOS cannot host an HTTP server. The design uses polling-based event refresh instead. No webhook tasks are included.
- The WebRTC.xcframework is provided by a separate spec (WebRTC tvOS fork) and is assumed available via `#if canImport(WebRTC)`
- `WebRTCConnectionState` enum (currently in `WebRTCStreamServiceProtocol.swift`) must be preserved when that file is deleted — move it to `StreamSessionManagerProtocol.swift` or a shared types file
