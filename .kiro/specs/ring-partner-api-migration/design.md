# Design Document: Ring Partner API Migration

## Overview

This design describes the migration of the RingAppleTV tvOS application from Ring's private consumer API (`api.ring.com/clients_api`) to the official Ring Partner API (Amazon Vision API at `api.amazonvision.com/v1`). The migration touches every layer of the networking stack:

1. **Authentication**: Replace email/password OAuth with OAuth 2.0 Device Authorization Grant (RFC 8628) for account linking — the user sees a code on the TV, completes authorization on their phone/computer, and the tvOS app polls for the token.
2. **Device discovery**: Replace the proprietary grouped-JSON device response with JSON:API-formatted device resources, changing device IDs from `Int` to `String`.
3. **Live streaming**: Replace SIP-over-TLS signaling (`SIPSignalingClient`) with WHEP (WebRTC-HTTP Egress Protocol) — a single HTTP POST carrying an SDP offer, receiving an SDP answer. WebRTC `RTCPeerConnection` remains for media transport.
4. **Events and media**: Point event history, video download, and snapshot endpoints at the Partner API equivalents.
5. **Error handling**: Replace `RingAPIError` with `PartnerAPIError`, adding rate-limit retry logic (handle 429 with `Retry-After` + exponential backoff) and proactive token refresh.
6. **Cleanup**: Delete all private API code, SIP signaling code, legacy DTOs, and `AppConfiguration.maxStreamDuration`.
7. **Background refresh**: Update `BackgroundRefreshManager` to use the new `DeviceService` (String IDs) and `MediaService` (replaces `SnapshotService`).

### Key Research Findings

- **WHEP protocol** ([IETF draft-ietf-wish-whep-02](https://www.ietf.org/archive/id/draft-ietf-wish-whep-02.txt)): WHEP uses a simple HTTP POST to a WHEP endpoint with `Content-Type: application/sdp` carrying the SDP offer. The server responds with `201 Created`, the SDP answer in the body, and a `Location` header pointing to the session resource. Session termination is an HTTP DELETE to that `Location` URL. ICE trickle is supported via HTTP PATCH but Ring's implementation bundles ICE candidates in the initial SDP exchange. Bearer token authentication is the standard WHEP auth mechanism.
- **OAuth 2.0 Device Authorization Grant** ([RFC 8628](https://tools.ietf.org/html/rfc8628)): Designed specifically for input-constrained devices like smart TVs. The device requests a device code and user code from the authorization server, displays the user code (and a verification URL or QR code) on screen, then polls the token endpoint until the user completes authorization on a separate device. The spec defines `slow_down` and `expired_token` error responses that the client must handle during polling.
- **Ring Partner API** ([developer.amazon.com/docs/ring](https://developer.amazon.com/docs/ring/api-documentation.html)): Uses JSON:API format for device discovery, OAuth 2.0 tokens for auth, and WHEP for live streaming. Base URL is `https://api.amazonvision.com/v1`. Rate limit is 100 TPS per partner.

### Assumptions and Open Questions

1. Ring's OAuth server at `oauth.ring.com` supports the Device Authorization Grant (RFC 8628). If it does not, the fallback QR code flow (Requirement 1, criterion 10) becomes the primary path.
2. The Partner API device resource includes a `status` attribute (or equivalent) indicating online/offline state. If not available, the app defaults to `true` and relies on streaming failures to surface offline devices.
3. The Partner API does not support triggering a new snapshot capture — only downloading the most recent cached image. If a trigger endpoint exists, it can be added as a future enhancement.
4. The Partner API supports a `limit` query parameter for event history. The client continues to enforce a 50-event cap client-side as a safety measure.
5. The Partner API `model` field values may not match existing `DeviceType` raw values exactly. The mapping uses a best-effort match with fallback to `.unknown`.
6. **RTSP fallback**: If WebRTC/WHEP proves untenable on tvOS (e.g., due to WebRTC framework availability issues or ICE connectivity problems), RTSP is a potential escape hatch. The Partner API may support RTSP streaming as an alternative. This is not implemented in the initial migration but noted as a contingency.

## Architecture

```mermaid
graph TD
    subgraph "tvOS App"
        UI["SwiftUI Views"]
        VM["ViewModels"]
        SC["ServiceContainer"]
        BRM["BackgroundRefreshManager"]

        subgraph "Service Layer"
            AS["AuthService<br/>(Device Code Flow)"]
            DS["DeviceService<br/>(JSON:API)"]
            ES["EventService"]
            MS["MediaService"]
            SSM["StreamSessionManager<br/>(WHEP + WebRTC)"]
        end

        subgraph "Networking"
            PAC["PartnerAPIClient<br/>(URLSession)"]
        end

        subgraph "Storage"
            KC["KeychainService"]
        end
    end

    subgraph "External"
        OA["oauth.ring.com<br/>(Auth Server)"]
        PA["api.amazonvision.com/v1<br/>(Partner API)"]
        WR["WebRTC Media<br/>(ICE/DTLS/SRTP)"]
    end

    UI --> VM
    VM --> SC
    SC --> AS
    SC --> DS
    SC --> ES
    SC --> MS
    SC --> SSM
    SC --> BRM

    BRM --> DS
    BRM --> MS

    AS --> PAC
    DS --> PAC
    ES --> PAC
    MS --> PAC
    SSM --> PAC

    SSM -->|RTCPeerConnection| WR

    PAC --> OA
    PAC --> PA

    AS --> KC
```

### Key Design Decisions

1. **Device Authorization Grant (RFC 8628) for tvOS auth**: tvOS has no web browser and limited text input. Rather than attempting to embed a web view or build a complex redirect flow, we use the Device Authorization Grant. The TV displays a short user code and URL (or QR code). The user opens the URL on their phone, enters the code, and authorizes. The tvOS app polls the token endpoint until authorization completes. This is the standard pattern used by YouTube, Netflix, and other tvOS apps. If Ring's OAuth server doesn't support the device code grant, we fall back to displaying a QR code encoding the full authorization URL so the user can scan it with their phone's camera and complete the standard authorization code flow there, with the tvOS app polling a lightweight callback mechanism. The polling loop handles `slow_down` (increase interval by 5s) and `expired_token` (prompt user to restart) per RFC 8628.

2. **Single `PartnerAPIClient` replaces both `DefaultRingAPIClient` and `WHEPClient`**: Rather than having a separate `WHEPClient` component, the WHEP HTTP calls (POST SDP offer, DELETE session) are methods on `PartnerAPIClient`. WHEP is just HTTP — there's no protocol-specific logic that warrants a separate abstraction. The `StreamSessionManager` calls `PartnerAPIClient` directly for SDP exchange. This avoids an unnecessary indirection layer.

3. **No client-side rate limiter**: The original design included a token-bucket rate limiter to stay below 100 TPS. This is over-engineered for a single-user tvOS app that will never approach 100 TPS. Instead, we simply handle 429 responses with retry: extract `Retry-After` if present, otherwise use exponential backoff starting at 1 second.

4. **`StreamSessionManager` replaces `DefaultWebRTCStreamService`**: The existing service mixes SIP signaling with WebRTC management. The new `StreamSessionManager` accepts a device ID and power source, delegates the SDP exchange to `PartnerAPIClient`, and manages the `RTCPeerConnection` directly. The `WebRTCStreamService` protocol is replaced by `StreamSessionManagerProtocol` accepting `(deviceId: String, powerSource: PowerSource)` instead of `StreamSessionResponse`. WHEP DELETE failures are best-effort — the local `RTCPeerConnection` is always closed regardless.

5. **Domain model ID migration (`Int` → `String`)**: The Partner API uses string identifiers in JSON:API format. All domain models (`RingDevice`, `RingEvent`, `StreamSession`) change their `id` and related foreign keys from `Int` to `String`. This is a breaking change that propagates through service protocols, view models, and views.

6. **`PartnerAPIError` with retry logic**: The new error enum includes `rateLimited(retryAfter: TimeInterval)` with built-in retry support. The `PartnerAPIClient` automatically retries on 429 responses (up to 3 times) and attempts one token refresh on 401 responses before failing. When `Retry-After` is absent, the client uses a default backoff of 1 second, doubling on each subsequent retry.

7. **Webhook handling deferred**: Requirement 6 specifies webhook event notifications. On tvOS, the app cannot host an HTTP server to receive webhooks directly. Webhook delivery requires a backend service. For the initial migration, we implement polling-based event refresh via the Event History API (Requirement 5). Webhook support is noted as a future enhancement requiring a companion backend service.

8. **`BackgroundRefreshManager` updated, not replaced**: The existing `BackgroundRefreshManager` structure is sound — it registers a `BGAppRefreshTask`, fetches devices, and pre-fetches snapshots for up to 10 devices. The migration updates its dependencies: `DeviceService` (now returns `[RingDevice]` with `String` IDs) and `MediaService` (replaces `SnapshotService`). The 10-device cap and silent-skip-on-failure behavior are preserved.

9. **`AppConfiguration.maxStreamDuration` removed**: Stream duration is now determined by the device's `PowerSource` (30s battery / 60s line-powered) rather than a global configuration value. The `maxStreamDuration` property is removed from `AppConfiguration`.

10. **RTSP fallback escape hatch**: If WebRTC/WHEP proves untenable on tvOS, RTSP is a potential fallback. This is not implemented in the initial migration but the architecture keeps the `StreamSessionManager` abstraction clean enough that swapping WHEP for RTSP would be localized to that component.

11. **Event pagination**: The `EventService` passes `limit=50` to the Partner API and sorts results descending by `createdAt`, consistent with existing behavior. Client-side capping at 50 events is retained as a safety measure.

12. **DeviceType mapping with `.unknown` fallback**: The Partner API `model` attribute may not match existing `DeviceType` raw values. The mapping uses `DeviceType(rawValue:) ?? .unknown` to handle unrecognized model strings gracefully.

## Components and Interfaces

### 1. `PartnerAPIClient` (New — replaces `DefaultRingAPIClient`)

The central HTTP client for all Partner API communication, including WHEP session management.

```swift
protocol PartnerAPIClientProtocol: Sendable {
    // Auth - Device Code Flow
    func requestDeviceCode(clientId: String) async throws -> DeviceCodeResponse
    func pollForToken(clientId: String, clientSecret: String, deviceCode: String) async throws -> AuthTokenResponse
    func refreshToken(clientId: String, clientSecret: String, refreshToken: String) async throws -> AuthTokenResponse

    // Devices
    func fetchDevices(token: String) async throws -> [PartnerDeviceResource]

    // Events
    func fetchEvents(deviceId: String, token: String, limit: Int) async throws -> [PartnerEventResource]

    // Media
    func downloadVideo(deviceId: String, eventId: String, token: String) async throws -> URL
    func downloadSnapshot(deviceId: String, token: String) async throws -> Data

    // WHEP (live streaming)
    func createWHEPSession(deviceId: String, sdpOffer: String, token: String) async throws -> WHEPSessionResponse
    func deleteWHEPSession(sessionURL: URL, token: String) async throws
}
```

**Base URLs:**
- Auth: `https://oauth.ring.com`
- API: `https://api.amazonvision.com/v1`

**Rate limiting**: No client-side rate limiter. On HTTP 429, extract `Retry-After` header if present; if absent, use exponential backoff starting at 1 second (1s → 2s → 4s). Maximum 3 retries.

**Token injection**: Every API request (non-auth) includes `Authorization: Bearer {token}`. On 401, attempt one token refresh before failing.

### 2. `AuthService` (Modified)

Updated to use Device Authorization Grant instead of email/password.

```swift
protocol AuthService: Sendable {
    /// Start the device code flow. Returns the user code and verification URL to display.
    func startDeviceCodeFlow() async throws -> DeviceCodeInfo
    /// Poll for authorization completion. Call repeatedly until success or expiry.
    /// Handles slow_down by increasing interval, expired_token by throwing expiredDeviceCode.
    func pollForAuthorization(deviceCode: String) async throws -> AuthToken
    /// Return a non-expired token, refreshing proactively if within 60s of expiry.
    func getValidToken() async throws -> AuthToken
    /// Clear all stored tokens and transition to unauthenticated state.
    func logout() async
    /// Whether a valid token exists.
    var isAuthenticated: Bool { get }
}
```

The `login(email:password:)` and `login(email:password:twoFactorCode:)` methods are removed entirely.

**Polling edge cases:**
- `authorization_pending`: Continue polling at current interval
- `slow_down`: Increase polling interval by 5 seconds before next attempt
- `expired_token`: Throw `PartnerAPIError.expiredDeviceCode`, prompt user to restart

### 3. `StreamSessionManager` (New — replaces `DefaultWebRTCStreamService`)

Orchestrates the full WHEP + WebRTC lifecycle. Calls `PartnerAPIClient` directly for SDP exchange (no separate WHEPClient).

```swift
protocol StreamSessionManagerProtocol: AnyObject, Sendable {
    /// Start a live stream for a device.
    func startStream(deviceId: String, powerSource: PowerSource) async throws
    /// Stop the current stream.
    func stopStream() async
    /// Current connection state.
    var connectionState: WebRTCConnectionState { get }
    var connectionStatePublisher: Published<WebRTCConnectionState>.Publisher { get }
}
```

**Lifecycle:**
1. Create `RTCPeerConnection` (receive-only, no local tracks)
2. Generate SDP offer
3. Send offer to WHEP endpoint via `PartnerAPIClient.createWHEPSession()`
4. Apply SDP answer as remote description
5. Wait for ICE `connected` state
6. Start session duration timer (30s battery / 60s line-powered)
7. On timer expiry or user stop: DELETE session via `PartnerAPIClient.deleteWHEPSession()`, close `RTCPeerConnection`
8. If DELETE fails: log error, still close local `RTCPeerConnection` (best-effort cleanup)

### 4. `DeviceService` (Modified)

Updated to parse JSON:API responses and expose `powerSource` and `isOnline`.

```swift
protocol DeviceService: Sendable {
    func fetchDevices() async throws -> [RingDevice]
    func filterDevices(_ devices: [RingDevice], by filter: DeviceFilter) -> [RingDevice]
    func sortDevices(_ devices: [RingDevice], by sort: DeviceSort) -> [RingDevice]
    func refreshDevices() async throws -> [RingDevice]
}
```

The implementation changes from parsing `DevicesWrapper` (grouped JSON) to parsing `PartnerDeviceResource` (JSON:API `data` array). Device `model` is mapped to `DeviceType` via `DeviceType(rawValue:) ?? .unknown`. Device `status` is mapped to `isOnline`, defaulting to `true` when absent.

### 5. `EventService` (Modified)

Updated to use Partner API event endpoints with string IDs and pagination.

```swift
protocol EventService: Sendable {
    func fetchEvents(for deviceId: String?) async throws -> [RingEvent]
    func fetchEventVideoURL(for event: RingEvent) async throws -> URL
}
```

The implementation passes `limit=50` to the Partner API, sorts events descending by `createdAt`, and enforces a client-side cap of 50 events.

### 6. `MediaService` (New — replaces `VideoService` + `SnapshotService`)

Consolidates video download and snapshot download into one service.

```swift
protocol MediaService: Sendable {
    func downloadVideo(deviceId: String, eventId: String) async throws -> URL
    func downloadSnapshot(deviceId: String) async throws -> Data
}
```

### 7. `BackgroundRefreshManager` (Modified)

Updated to use `DeviceService` (String IDs) and `MediaService` (replaces `SnapshotService`).

```swift
final class BackgroundRefreshManager: @unchecked Sendable {
    private let deviceService: DeviceService
    private let mediaService: MediaService  // was: snapshotService: SnapshotService

    init(deviceService: DeviceService, mediaService: MediaService) { ... }

    func registerBackgroundTask() { ... }
    func scheduleNextRefresh() { ... }
}
```

**Behavior (unchanged):**
- Fetches device list via `DeviceService`
- Pre-fetches snapshots for up to 10 devices via `MediaService.downloadSnapshot(deviceId:)` with `String` device IDs
- Silently skips individual snapshot failures
- Schedules next refresh at 15-minute interval

### 8. `ServiceContainer` (Modified)

Updated to wire new services and `BackgroundRefreshManager`.

```swift
@MainActor
final class ServiceContainer: ObservableObject {
    // Infrastructure
    let apiClient: PartnerAPIClientProtocol  // was: RingAPIClient
    let keychainService: KeychainService
    let cacheService: CacheService

    // Domain Services
    let authService: AuthService
    let deviceService: DeviceService
    let eventService: EventService
    let mediaService: MediaService           // replaces videoService + snapshotService
    let streamSessionManager: StreamSessionManagerProtocol?  // replaces webRTCService

    // Background
    let backgroundRefreshManager: BackgroundRefreshManager

    // ViewModels
    let authViewModel: AuthViewModel
    let dashboardViewModel: DashboardViewModel
    let eventsViewModel: EventsViewModel
}
```

Key wiring changes:
- `PartnerAPIClient` replaces `DefaultRingAPIClient`
- `MediaService` replaces `VideoService` + `SnapshotService`
- `StreamSessionManager` replaces `DefaultWebRTCStreamService`
- `BackgroundRefreshManager` is wired with `DeviceService` and `MediaService`
- `videoService` and `snapshotService` properties removed

## Data Models

### New DTOs (Partner API Responses)

```swift
/// OAuth 2.0 Device Authorization Grant response
struct DeviceCodeResponse: Codable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int  // polling interval in seconds

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Info displayed to the user during device code flow
struct DeviceCodeInfo {
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: TimeInterval
    let pollingInterval: TimeInterval
    let deviceCode: String  // internal, not displayed
}

/// JSON:API device resource from Partner API
struct PartnerDeviceResource: Codable {
    let id: String
    let type: String
    let attributes: DeviceAttributes

    struct DeviceAttributes: Codable {
        let name: String
        let model: String
        let firmwareVersion: String?
        let powerSource: String   // "battery" or "line"
        let status: String?       // "online" / "offline", may be absent

        enum CodingKeys: String, CodingKey {
            case name, model, status
            case firmwareVersion = "firmware_version"
            case powerSource = "power_source"
        }
    }

    func toDomain() -> RingDevice {
        RingDevice(
            id: id,
            name: attributes.name,
            model: attributes.model,
            deviceType: RingDevice.DeviceType(rawValue: attributes.model) ?? .unknown,
            firmwareVersion: attributes.firmwareVersion,
            powerSource: PowerSource(rawValue: attributes.powerSource) ?? .battery,
            isOnline: attributes.status.map { $0 == "online" } ?? true
        )
    }
}

/// JSON:API wrapper for device list response
struct PartnerDeviceListResponse: Codable {
    let data: [PartnerDeviceResource]
}

/// Partner API event resource
struct PartnerEventResource: Codable {
    let id: String
    let deviceId: String
    let type: String       // "motion", "ding", "on_demand"
    let createdAt: String  // ISO 8601
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case type
        case createdAt = "created_at"
        case duration
    }

    func toDomain() -> RingEvent {
        let formatter = ISO8601DateFormatter()
        return RingEvent(
            id: id,
            deviceId: deviceId,
            eventType: RingEvent.EventType(rawValue: type) ?? .motion,
            createdAt: formatter.date(from: createdAt) ?? Date(),
            duration: duration.map { TimeInterval($0) }
        )
    }
}

/// WHEP session creation response
struct WHEPSessionResponse {
    let sdpAnswer: String
    let sessionURL: URL
}

/// Partner API error response body
struct PartnerAPIErrorBody: Codable {
    let code: String?
    let message: String?
}
```

### Modified Domain Models

```swift
/// Updated RingDevice — String ID, added powerSource, isOnline with default
struct RingDevice: Codable, Identifiable, Equatable {
    let id: String                    // Changed: Int → String
    let name: String                  // Changed: was 'description'
    let model: String                 // New
    let deviceType: DeviceType
    let firmwareVersion: String?
    let powerSource: PowerSource      // New
    var isOnline: Bool                // Default: true when Partner API status absent

    enum DeviceType: String, Codable, CaseIterable {
        case doorbell
        case doorbellPro = "doorbell_pro"
        case doorbellV2 = "doorbell_v2"
        case stickupCam = "stickup_cam"
        case spotlightCam = "spotlight_cam"
        case floodlightCam = "floodlight_cam"
        case indoorCam = "indoor_cam"
        case unknown
        // .unknown is the fallback for unrecognized Partner API model strings
    }
}

/// Power source determines session duration limit
enum PowerSource: String, Codable {
    case battery
    case line

    var sessionDurationLimit: TimeInterval {
        switch self {
        case .battery: return 30
        case .line: return 60
        }
    }
}

/// Updated RingEvent — String IDs
struct RingEvent: Codable, Identifiable, Equatable {
    let id: String                    // Changed: Int → String
    let deviceId: String              // Changed: Int → String
    let eventType: EventType
    let createdAt: Date
    let duration: TimeInterval?

    enum EventType: String, Codable { /* unchanged */ }
}

/// Updated StreamSession — WHEP fields replace SIP fields
struct StreamSession: Equatable {
    let deviceId: String              // Changed: Int → String
    let sessionURL: URL               // New: WHEP session resource URL
    let powerSource: PowerSource      // New
    let createdAt: Date
    let maxDuration: TimeInterval     // Derived from powerSource

    var isValid: Bool { remainingTime > 0 }
    var remainingTime: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(createdAt))
    }
}

/// Updated AuthToken — added clientId scope
struct AuthToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String?
    let tokenType: String
    let clientId: String?             // New: from Partner API token response

    var isExpired: Bool { Date() >= expiresAt }
    var needsRefresh: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// New error enum replacing RingAPIError
enum PartnerAPIError: Error, Equatable {
    case unauthorized                 // 401
    case forbidden                    // 403
    case notFound                     // 404
    case rateLimited(retryAfter: TimeInterval)  // 429
    case serverError(Int)             // 5xx
    case networkError(String)
    case decodingError(String)
    case authorizationPending         // Device code flow: user hasn't authorized yet
    case slowDown                     // Device code flow: polling too fast
    case expiredDeviceCode            // Device code flow: code expired

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "Your session has expired. Please re-link your Ring account."
        case .forbidden:
            return "Access denied. Please check your account permissions."
        case .notFound:
            return "The requested resource was not found."
        case .rateLimited:
            return "Too many requests. Please wait a moment."
        case .serverError:
            return "Ring servers are temporarily unavailable. Please try later."
        case .networkError:
            return "Network connection error. Please check your connection."
        case .decodingError:
            return "Unexpected response from Ring. Please try again."
        case .authorizationPending:
            return "Waiting for authorization. Please complete sign-in on your phone."
        case .slowDown:
            return "Please wait a moment before trying again."
        case .expiredDeviceCode:
            return "Authorization code expired. Please start the sign-in process again."
        }
    }
}
```

### Updated `AppConfiguration`

```swift
struct AppConfiguration: Codable, Equatable {
    var useMocks: Bool
    var enableDebugLogging: Bool
    var streamTimeoutSeconds: TimeInterval
    // maxStreamDuration: REMOVED — duration now derived from PowerSource
    var deviceRefreshInterval: TimeInterval
    var eventHistoryHours: Int
    var maxEventCount: Int
    var cacheExpirationSeconds: TimeInterval
    var enableCrashReporting: Bool
    var enableLocalAnalytics: Bool
}
```

### Updated `Constants.API`

```swift
enum Constants {
    enum API {
        static let oauthBaseURL = "https://oauth.ring.com"
        static let partnerAPIBaseURL = "https://api.amazonvision.com/v1"
        // All clients_api and doorbots constants REMOVED
    }
}
```

### Deleted Models and Code

| File | Reason |
|---|---|
| `SIPSignalingClient.swift` | SIP signaling replaced by WHEP |
| `SIPError` enum | No longer needed |
| `StreamSessionResponse.swift` | SIP session params replaced by `WHEPSessionResponse` |
| `DevicesWrapper` struct | Private API grouped format replaced by JSON:API |
| `RingDeviceResponse.swift` | Replaced by `PartnerDeviceResource` |
| `RingEventResponse.swift` | Replaced by `PartnerEventResource` |
| `RingAPIError.swift` | Replaced by `PartnerAPIError` |
| `DefaultRingAPIClient.swift` | Replaced by `PartnerAPIClient` |
| `TwoFactorMethod` enum | No 2FA in Partner API flow |
| `VideoURLWrapper` struct | Internal to old API client |
| `DefaultVideoService.swift` | Replaced by `MediaService` |
| `DefaultSnapshotService.swift` | Replaced by `MediaService` |
| `VideoServiceProtocol.swift` | Replaced by `MediaService` protocol |
| `SnapshotServiceProtocol.swift` | Replaced by `MediaService` protocol |
| `DefaultWebRTCStreamService.swift` | Replaced by `StreamSessionManager` |
| `WebRTCStreamServiceProtocol.swift` | Replaced by `StreamSessionManagerProtocol` |


## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: Token Keychain Round-Trip

*For any* valid `AuthToken` (with arbitrary `accessToken`, `refreshToken`, `expiresAt`, `scope`, `tokenType`, and `clientId` values), storing the token in the Keychain and then retrieving it should produce an `AuthToken` equal to the original.

**Validates: Requirements 1.4, 1.5, 9.5**

### Property 2: Proactive Refresh Threshold

*For any* `AuthToken` with an arbitrary `expiresAt` date, the `needsRefresh` property should return `true` if and only if the current time is within 60 seconds of `expiresAt` (i.e., `now >= expiresAt - 60`), and `isExpired` should return `true` if and only if `now >= expiresAt`.

**Validates: Requirements 1.6**

### Property 3: Bearer Token Header Injection

*For any* non-empty access token string and any Partner API endpoint path, the constructed `URLRequest` should contain an `Authorization` header with the value `"Bearer {token}"` where `{token}` is the exact access token string.

**Validates: Requirements 1.8**

### Property 4: Logout Clears All Token State

*For any* initial token state (with arbitrary stored tokens), after calling `logout()`, the `isAuthenticated` property should be `false` and retrieving tokens from the Keychain should return `nil`.

**Validates: Requirements 1.9**

### Property 5: Device Resource JSON:API Round-Trip with Fallbacks

*For any* valid `PartnerDeviceResource` (with arbitrary `id` string, `type`, and `attributes` including `name`, `model`, `firmwareVersion`, `powerSource`, and optional `status`), serializing to JSON:API format and then parsing back should produce an equivalent `PartnerDeviceResource`. Furthermore, calling `toDomain()` should produce a `RingDevice` whose `id`, `name`, `model`, and `powerSource` match the original resource's values. When the `model` attribute does not match any `DeviceType` raw value, `deviceType` should be `.unknown`. When `status` is absent, `isOnline` should default to `true`; when `status` is `"online"`, `isOnline` should be `true`; when `status` is `"offline"`, `isOnline` should be `false`.

**Validates: Requirements 2.2, 2.3, 2.6, 2.7, 2.8, 9.1, 9.2, 9.6**

### Property 6: Event Resource Round-Trip

*For any* valid `PartnerEventResource` (with arbitrary `id` string, `deviceId` string, `type`, ISO 8601 `createdAt`, and optional `duration`), serializing to JSON and then parsing back should produce an equivalent `PartnerEventResource`. Furthermore, calling `toDomain()` should produce a `RingEvent` whose `id`, `deviceId`, `eventType`, and `duration` match the original resource's values.

**Validates: Requirements 5.2, 5.3, 9.3**

### Property 7: Event Sorting and Capping

*For any* list of `RingEvent` objects (of arbitrary length and with arbitrary `createdAt` dates), after applying the EventService's sort-and-cap logic, the result should be sorted in descending order by `createdAt` and contain at most 50 events.

**Validates: Requirements 5.5**

### Property 8: WHEP Session Round-Trip

*For any* valid device ID string and any valid SDP offer string, the constructed WHEP HTTP request should have: (a) method POST, (b) URL matching `https://api.amazonvision.com/v1/devices/{deviceId}/media/streaming/whep/sessions`, (c) `Content-Type` header equal to `application/sdp`, and (d) body equal to the SDP offer string. Furthermore, for any valid SDP answer string and any valid session URL, when wrapped in an HTTP 201 response (SDP answer in the body, session URL in the `Location` header), the WHEP response parser should extract the exact SDP answer string and the exact session URL, and the resulting `StreamSession` should store the correct `sessionURL` and `maxDuration` derived from the device's `PowerSource`.

**Validates: Requirements 3.1, 3.2, 3.3, 9.4**

### Property 9: HTTP Error Status Mapping

*For any* HTTP status code in the range 400–599, the `PartnerAPIClient` error mapping function should produce the correct `PartnerAPIError` case: 401 → `.unauthorized`, 403 → `.forbidden`, 404 → `.notFound`, 429 → `.rateLimited(retryAfter:)`, 500–599 → `.serverError(statusCode)`, and all other 4xx → a defined error case. No status code in the error range should produce an unhandled case or crash.

**Validates: Requirements 2.5, 3.7, 4.3, 4.6, 5.4, 7.1**

### Property 10: PartnerAPIError User Messages

*For any* `PartnerAPIError` case (including all associated values), the `userMessage` computed property should return a non-empty `String` that does not contain technical jargon like "HTTP", status codes, or stack traces.

**Validates: Requirements 7.5**

### Property 11: Slow-Down Polling Interval Increase

*For any* current polling interval (positive `TimeInterval`), when the authorization server returns a `slow_down` error, the next polling interval should be exactly `currentInterval + 5` seconds.

**Validates: Requirements 1.11**

### Property 12: Background Refresh Invariants

*For any* list of devices (of arbitrary length) and any pattern of individual snapshot download failures, the `BackgroundRefreshManager` should: (a) request snapshots for at most `min(deviceCount, 10)` devices, and (b) continue processing remaining devices when individual snapshot downloads fail, never aborting the entire refresh cycle due to a single device failure.

**Validates: Requirements 10.4, 10.5**

## Error Handling

### HTTP Error Mapping

All Partner API HTTP errors are mapped through a single `mapStatusCode` function in `PartnerAPIClient`:

| HTTP Status | `PartnerAPIError` Case | Recovery Action |
|---|---|---|
| 401 | `.unauthorized` | Attempt one token refresh; if refresh fails, clear tokens and prompt re-linking |
| 403 | `.forbidden` | Display user message, no automatic retry |
| 404 | `.notFound` | Display user message (e.g., "device not found" or "no video available") |
| 429 | `.rateLimited(retryAfter:)` | Extract `Retry-After` header if present; if absent, use exponential backoff (1s → 2s → 4s). Retry up to 3 times. |
| 500–599 | `.serverError(statusCode)` | Display user message, no automatic retry |
| Network failure | `.networkError(message)` | Display connectivity message |
| JSON decode failure | `.decodingError(message)` | Log details, display generic error message |

### Device Code Flow Errors

| Scenario | `PartnerAPIError` Case | Handling |
|---|---|---|
| User hasn't authorized yet | `.authorizationPending` | Continue polling at the specified interval |
| Polling too fast | `.slowDown` | Increase polling interval by 5 seconds |
| Device code expired | `.expiredDeviceCode` | Display message, prompt user to restart flow |
| Token endpoint returns error | `.unauthorized` | Display error, prompt restart |

### WHEP Streaming Errors

| Scenario | Handling |
|---|---|
| WHEP POST returns 4xx/5xx | Map to `PartnerAPIError`, transition connection state to `.failed`, display user message |
| `RTCPeerConnection` ICE fails | Transition to `.failed("ICE connection failed")`, send DELETE to session URL if available |
| Session timer expires | Send DELETE to session URL, close `RTCPeerConnection`, transition to `.disconnected` |
| DELETE session fails | Log error, still close local `RTCPeerConnection` (best-effort cleanup) |
| WebRTC framework unavailable | `StreamSessionManager` returns `nil` from `ServiceContainer`, UI shows "Live streaming not available" |

### Token Lifecycle Errors

| Scenario | Handling |
|---|---|
| Token refresh succeeds | Replace stored tokens, retry original request |
| Token refresh returns 401 | Clear all tokens, transition to unauthenticated, prompt re-linking |
| Token refresh network error | Propagate `.networkError` to caller |
| Keychain read/write fails | Propagate `KeychainError`, fall back to in-memory token storage |

### Background Refresh Errors

| Scenario | Handling |
|---|---|
| Device list fetch fails | Mark task as failed, schedule next refresh |
| Individual snapshot download fails | Silently skip device, continue with remaining devices |
| Background task expires (system) | Cancel work task, system handles cleanup |

## Testing Strategy

### Property-Based Testing Applicability

This feature is well-suited for property-based testing. The core logic involves:
- **Data serialization/deserialization** (JSON:API parsing, token storage) — classic round-trip properties
- **Pure mapping functions** (`toDomain()`, error mapping, URL construction) — input varies meaningfully, universal properties hold
- **State predicates** (`needsRefresh`, `isExpired`) — boolean functions of time, testable across the full input space
- **Sorting/capping logic** (event list processing) — invariants that hold for all input sizes
- **Fallback behavior** (DeviceType `.unknown`, isOnline default) — edge cases covered by generators

PBT is NOT appropriate for:
- Webhook handling (deferred, requires backend)
- Actual HTTP calls to Ring's servers (integration tests)
- WebRTC `RTCPeerConnection` behavior (external framework)
- Keychain access control configuration (smoke tests)
- Codebase cleanup verification (smoke tests / grep)

### Property-Based Testing Configuration

- **Library**: [SwiftCheck](https://github.com/typelift/SwiftCheck) or `swift-testing` with custom generators
- **Minimum iterations**: 100 per property test
- **Tag format**: `Feature: ring-partner-api-migration, Property {N}: {title}`
- Each correctness property (1–12) maps to exactly one property-based test

### Test Plan

#### Property-Based Tests (12 tests)

| Test | Property | What Varies |
|---|---|---|
| `testTokenKeychainRoundTrip` | Property 1 | Random token strings, dates, optional fields |
| `testProactiveRefreshThreshold` | Property 2 | Random `expiresAt` dates relative to `now` |
| `testBearerTokenHeaderInjection` | Property 3 | Random token strings, API endpoint paths |
| `testLogoutClearsAllTokenState` | Property 4 | Random initial token states |
| `testDeviceResourceRoundTripWithFallbacks` | Property 5 | Random device IDs, names, models (known + unknown), power sources, optional status |
| `testEventResourceRoundTrip` | Property 6 | Random event IDs, types, ISO 8601 dates, durations |
| `testEventSortingAndCapping` | Property 7 | Random event lists of varying sizes (0–200) with random dates |
| `testWHEPSessionRoundTrip` | Property 8 | Random device IDs, SDP strings, session URLs, power sources |
| `testHTTPErrorStatusMapping` | Property 9 | Random HTTP status codes 400–599 |
| `testPartnerAPIErrorUserMessages` | Property 10 | All `PartnerAPIError` cases with random associated values |
| `testSlowDownPollingIntervalIncrease` | Property 11 | Random current polling intervals |
| `testBackgroundRefreshInvariants` | Property 12 | Random device lists (0–50), random failure patterns |

#### Unit Tests (Example-Based)

| Test | Validates | Description |
|---|---|---|
| `testTokenRefreshOn401ClearsTokens` | Req 1.7 | Mock 401 on refresh → tokens cleared, `isAuthenticated` false |
| `testDeviceCodeFlowFallbackToQR` | Req 1.10 | Mock unsupported grant type → QR code fallback triggered |
| `testExpiredDeviceCodePromptsRestart` | Req 1.12 | Mock expired device code → `expiredDeviceCode` error raised |
| `testEmptyDeviceListReturnsEmpty` | Req 2.4 | Empty JSON:API `data` array → empty `[RingDevice]`, no error |
| `testSessionTimerStartsOnICEConnected` | Req 3.4 | Mock ICE connected → timer started with correct duration |
| `testSessionTimerExpiryTerminatesStream` | Req 3.5 | Mock timer expiry → DELETE sent, connection closed |
| `testManualStopSendsDeleteAndCloses` | Req 3.6 | Call `stopStream()` → DELETE sent, connection closed |
| `testReceiveOnlyMode` | Req 3.8 | After setup, no local senders have tracks |
| `testDeleteFailureStillClosesConnection` | Req 3.9 | Mock DELETE failure → `RTCPeerConnection` still closed |
| `testVideoURLExtraction` | Req 4.2 | Mock video download response → URL returned |
| `testSnapshotDataPassthrough` | Req 4.5 | Mock image data response → raw data returned |
| `test401TriggersOneTokenRefresh` | Req 7.3 | Mock 401 on API call → refresh attempted → request retried |
| `testRetryAfterAbsentUsesExponentialBackoff` | Req 7.6 | Mock 429 without Retry-After → 1s, 2s, 4s backoff |
| `testConstantsAPIReferencesPartnerAPI` | Req 8.11 | Verify `Constants.API` contains `amazonvision.com` URLs |

#### Integration Tests

| Test | Validates | Description |
|---|---|---|
| `testDeviceFetchEndToEnd` | Req 2.1 | Mock HTTP client verifies GET to correct URL with Bearer token |
| `testEventFetchEndToEnd` | Req 5.1 | Mock HTTP client verifies GET to correct events URL |
| `testEventFetchPassesLimit50` | Req 5.6 | Mock HTTP client verifies `limit=50` query parameter |
| `testVideoDownloadRequest` | Req 4.1 | Mock HTTP client verifies POST to video download URL |
| `testSnapshotDownloadRequest` | Req 4.4 | Mock HTTP client verifies POST to image download URL |
| `testRateLimitRetry` | Req 7.2 | Mock 429 with Retry-After → verify retry count and delay |
| `testBackgroundRefreshUsesMediaService` | Req 10.1, 10.2, 10.3 | Mock DeviceService + MediaService, verify BackgroundRefreshManager calls correct methods with String IDs |

#### Smoke Tests (Codebase Cleanup Verification)

| Test | Validates | Description |
|---|---|---|
| `testNoPrivateAPIReferences` | Req 8.1, 8.2 | Grep for `clients_api`, `ring_official_ios`, `api.ring.com` → zero matches |
| `testSIPCodeRemoved` | Req 8.3 | Verify `SIPSignalingClient.swift`, `SIPError`, SIP model fields are absent |
| `testLegacyDTOsRemoved` | Req 8.4–8.8 | Verify `DevicesWrapper`, `RingDeviceResponse`, `RingEventResponse`, `StreamSessionResponse`, `RingAPIError` are absent |
| `testLegacyServicesRemoved` | Req 8.9, 8.10 | Verify `DefaultWebRTCStreamService`, `WebRTCStreamService` protocol are absent |
| `testMaxStreamDurationRemoved` | Req 8.12 | Verify `maxStreamDuration` is absent from `AppConfiguration` |
| `testDomainModelTypes` | Req 9.1, 9.3, 9.4, 9.5 | Verify `RingDevice.id` is `String`, `RingEvent.id` is `String`, `StreamSession` has `sessionURL`, `AuthToken` has `clientId` |
