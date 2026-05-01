# Requirements Document

## Introduction

This document specifies the requirements for migrating the RingAppleTV tvOS application from Ring's private/undocumented consumer API (`api.ring.com/clients_api`) to the official Ring Partner API (Amazon Vision API at `api.amazonvision.com/v1`). The migration replaces the authentication mechanism (from email/password OAuth to OAuth 2.0 authorization code grant with account linking), the device discovery format (from proprietary JSON to JSON:API), the live streaming protocol (from SIP-over-TLS signaling to WHEP), and the event/media retrieval endpoints. The existing `SIPSignalingClient` is eliminated entirely in favor of a simple WHEP HTTP client. WebRTC (`RTCPeerConnection`, SDP, media rendering) remains required — WHEP uses WebRTC under the hood but replaces the SIP signaling layer with standard HTTP.

## Glossary

- **Partner_API_Client**: The HTTP networking layer that communicates with the Ring Partner API at `api.amazonvision.com/v1`
- **Auth_Service**: The service managing OAuth 2.0 token lifecycle, including authorization code exchange, token refresh, and secure storage
- **WHEP_Client**: The HTTP client that initiates and terminates live video streams using the WHEP (WebRTC-HTTP Egress Protocol) — sends an SDP offer via HTTP POST and receives an SDP answer in the response body
- **Device_Service**: The service that fetches and manages Ring device data from the Partner API's JSON:API device endpoint
- **Event_Service**: The service that retrieves event history from the Partner API's event endpoint
- **Media_Service**: The service that downloads video clips and image snapshots from the Partner API's media endpoints
- **Webhook_Handler**: The component that receives and processes real-time push notifications (motion, doorbell press, device status) delivered via webhooks
- **Stream_Session_Manager**: The component that manages WHEP stream session lifecycle, including session duration enforcement and cleanup
- **JSON:API**: The JSON:API specification format used by the Partner API for device discovery responses, with `data`, `type`, `id`, `attributes`, and `relationships` fields
- **WHEP**: WebRTC-HTTP Egress Protocol — a standard protocol for consuming media from a server using HTTP POST to exchange SDP offer/answer, eliminating the need for SIP signaling
- **Account_Linking**: The OAuth 2.0 flow where a user authorizes the partner application to access their Ring account via a browser-based consent screen, producing an authorization code
- **Session_Duration_Limit**: The maximum allowed duration for a live stream session — 30 seconds for battery-powered devices, 60 seconds for line-powered devices

## Requirements

### Requirement 1: OAuth 2.0 Device Authorization Grant Authentication

**User Story:** As a tvOS app user, I want to link my Ring account by entering a code shown on my TV screen, so that the app can access my Ring devices without requiring me to type an email and password on the remote.

#### Acceptance Criteria

1. WHEN the user initiates account linking, THE Auth_Service SHALL request a device code and user code from the authorization server at `https://oauth.ring.com/oauth/device/code` with the partner `client_id`, per RFC 8628 (Device Authorization Grant)
2. THE Auth_Service SHALL display the user code and verification URL (or a QR code encoding the verification URL) on the tvOS screen, so the user can complete authorization on their phone or computer
3. THE Auth_Service SHALL poll the token endpoint at `https://oauth.ring.com/oauth/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code`, the `device_code`, `client_id`, and `client_secret` at the interval specified by the authorization server
4. THE Auth_Service SHALL store the `client_secret` securely in the tvOS Keychain, never embedding it in plaintext source code or user-accessible storage
5. WHEN a valid access token and refresh token are received, THE Auth_Service SHALL persist both tokens in the tvOS Keychain with appropriate access control attributes
6. WHEN the access token is within 60 seconds of expiry, THE Auth_Service SHALL proactively refresh it by sending a POST request to `https://oauth.ring.com/oauth/token` with `grant_type=refresh_token`, the `refresh_token`, `client_id`, and `client_secret`
7. WHEN a token refresh fails with an HTTP 401 response, THE Auth_Service SHALL clear all stored tokens and transition the app to the unauthenticated state, prompting the user to re-link their account
8. THE Auth_Service SHALL include the access token as a Bearer token in the `Authorization` header of every Partner API request
9. WHEN the user initiates logout, THE Auth_Service SHALL delete all stored tokens from the Keychain and clear any in-memory token cache
10. IF the authorization server does not support the Device Authorization Grant, THE Auth_Service SHALL fall back to displaying a QR code encoding the full authorization URL for the user to scan and complete the standard authorization code flow on their phone

### Requirement 2: Partner API Device Discovery

**User Story:** As a tvOS app user, I want to see all my Ring cameras and doorbells, so that I can select a device to view its live stream or event history.

#### Acceptance Criteria

1. WHEN the user requests the device list, THE Device_Service SHALL send a GET request to `https://api.amazonvision.com/v1/devices` with the Bearer access token
2. WHEN the Partner API returns a JSON:API response, THE Device_Service SHALL parse the `data` array, extracting each device's `id`, `type`, and `attributes` (including device name, model, firmware version, and power source)
3. THE Device_Service SHALL map each JSON:API device resource to the domain `RingDevice` model, preserving the device `id` as a String (the Partner API uses string identifiers, not integers)
4. WHEN the Partner API returns an empty `data` array, THE Device_Service SHALL return an empty device list without raising an error
5. IF the Partner API returns an HTTP error status (4xx or 5xx), THEN THE Device_Service SHALL map the error to a descriptive `PartnerAPIError` and propagate it to the caller
6. THE Device_Service SHALL distinguish between battery-powered and line-powered devices based on the `power_source` attribute, as this determines the Session_Duration_Limit for live streaming

### Requirement 3: WHEP Live Video Streaming

**User Story:** As a tvOS app user, I want to watch a live stream from my Ring camera, so that I can see what is happening in real time.

#### Acceptance Criteria

1. WHEN the user requests a live stream for a device, THE WHEP_Client SHALL create a local SDP offer using `RTCPeerConnection` and send it as an HTTP POST to `https://api.amazonvision.com/v1/devices/{device_id}/media/streaming/whep/sessions` with `Content-Type: application/sdp` and the Bearer access token
2. WHEN the Partner API returns an HTTP 201 response with `Content-Type: application/sdp`, THE WHEP_Client SHALL extract the SDP answer from the response body and apply it as the remote description on the `RTCPeerConnection`
3. WHEN the Partner API returns an HTTP 201 response, THE WHEP_Client SHALL extract the session resource URL from the `Location` response header for use in session termination
4. WHEN the `RTCPeerConnection` transitions to the `connected` ICE state, THE Stream_Session_Manager SHALL begin a countdown timer set to the device's Session_Duration_Limit (30 seconds for battery-powered, 60 seconds for line-powered)
5. WHEN the session duration timer expires, THE Stream_Session_Manager SHALL terminate the stream by sending an HTTP DELETE to the session resource URL and closing the `RTCPeerConnection`
6. WHEN the user manually stops the stream, THE Stream_Session_Manager SHALL terminate the stream by sending an HTTP DELETE to the session resource URL and closing the `RTCPeerConnection`
7. IF the WHEP POST request fails with an HTTP error, THEN THE WHEP_Client SHALL map the error to a descriptive `PartnerAPIError` and transition the connection state to `failed`
8. THE WHEP_Client SHALL set the `RTCPeerConnection` to receive-only mode (no local audio or video tracks added), as the tvOS app only consumes the camera feed

### Requirement 4: SIP Signaling Removal

**User Story:** As a developer, I want to remove the SIP signaling layer, so that the codebase is simplified and only uses the supported WHEP protocol.

#### Acceptance Criteria

1. THE Partner_API_Client SHALL operate without any SIP signaling code — the `SIPSignalingClient` class, `SIPError` enum, and all SIP-related models (`sipServerIp`, `sipServerPort`, `sipSessionId`, `sipFrom`, `sipTo`, `sipToken`, `sipEndpoints`) SHALL be deleted from the codebase
2. THE `StreamSessionResponse` model SHALL be replaced with a WHEP-specific response model that captures the SDP answer body and the session resource URL from the `Location` header
3. THE `DefaultWebRTCStreamService` SHALL be refactored to use the WHEP_Client for SDP exchange instead of the `SIPSignalingClient`, eliminating all SIP INVITE, SIP INFO (ICE relay), and SIP BYE message construction
4. THE `WebRTCStreamService` protocol SHALL accept a device ID and power source type as input (instead of a `StreamSessionResponse` with SIP parameters), delegating the WHEP HTTP exchange to the WHEP_Client internally

### Requirement 5: Event History Retrieval

**User Story:** As a tvOS app user, I want to browse past motion and doorbell events, so that I can review what happened when I was away.

#### Acceptance Criteria

1. WHEN the user requests event history for a device, THE Event_Service SHALL send a GET request to `https://api.amazonvision.com/v1/history/devices/{device_id}/events` with the Bearer access token
2. WHEN the Partner API returns an event list, THE Event_Service SHALL parse each event's `id`, `type` (motion, ding, on_demand), `created_at` timestamp, and `duration` fields
3. THE Event_Service SHALL map each Partner API event to the domain `RingEvent` model, adapting field names and formats as needed (the Partner API uses ISO 8601 timestamps)
4. IF the Partner API returns an HTTP error status, THEN THE Event_Service SHALL map the error to a descriptive `PartnerAPIError` and propagate it to the caller

### Requirement 6: Video Clip Download

**User Story:** As a tvOS app user, I want to play back recorded video clips from past events, so that I can review footage in detail.

#### Acceptance Criteria

1. WHEN the user requests a video clip for an event, THE Media_Service SHALL send a POST request to `https://api.amazonvision.com/v1/devices/{device_id}/media/video/download` with the event identifier and the Bearer access token
2. WHEN the Partner API returns a download URL or video data, THE Media_Service SHALL provide the playable video URL to the video player
3. IF the Partner API returns an HTTP error (including 404 for events without video), THEN THE Media_Service SHALL map the error to a descriptive `PartnerAPIError` and propagate it to the caller

### Requirement 7: Image Snapshot Download

**User Story:** As a tvOS app user, I want to see a recent snapshot from my camera, so that I can quickly check the current view without starting a live stream.

#### Acceptance Criteria

1. WHEN the user requests a snapshot for a device, THE Media_Service SHALL send a POST request to `https://api.amazonvision.com/v1/devices/{device_id}/media/image/download` with the Bearer access token
2. WHEN the Partner API returns image data, THE Media_Service SHALL provide the raw image data (JPEG or PNG) to the caller
3. IF the Partner API returns an HTTP error, THEN THE Media_Service SHALL map the error to a descriptive `PartnerAPIError` and propagate it to the caller

### Requirement 8: Webhook Event Notifications (Deferred)

**User Story:** As a tvOS app user, I want to receive real-time notifications when motion is detected or my doorbell is pressed, so that I can respond promptly.

**Note:** This requirement is deferred. tvOS apps cannot host an HTTP server to receive webhook callbacks directly. Webhook delivery requires a companion backend service. For the initial migration, the app uses polling-based event refresh via the Event History API (Requirement 5). Webhook support is a future enhancement.

#### Acceptance Criteria (Future — not implemented in this migration)

1. A companion backend service SHALL register a webhook endpoint with the Partner API to receive real-time event notifications for motion, doorbell press, and device status changes
2. The backend service SHALL forward relevant notifications to the tvOS app via push notifications (APNs)
3. WHEN a push notification is received, THE app SHALL update the event list and display a UI notification
4. IF a notification has an unrecognized event type, THE app SHALL log the event type and discard the notification without crashing

### Requirement 9: Partner API Error Handling and Rate Limiting

**User Story:** As a tvOS app user, I want the app to handle API errors gracefully, so that I see helpful messages instead of crashes or blank screens.

#### Acceptance Criteria

1. THE Partner_API_Client SHALL map all Partner API HTTP error responses to a `PartnerAPIError` enum with cases for: `unauthorized` (401), `forbidden` (403), `notFound` (404), `rateLimited` (429), `serverError` (5xx), `networkError`, and `decodingError`
2. WHEN the Partner API returns an HTTP 429 (rate limited) response, THE Partner_API_Client SHALL extract the `Retry-After` header value and wait the specified duration before retrying the request, up to a maximum of 3 retries
3. WHEN the Partner API returns an HTTP 401 response on a non-authentication endpoint, THE Partner_API_Client SHALL attempt one token refresh via the Auth_Service before failing the request
4. THE Partner_API_Client SHALL enforce a client-side request rate below 100 transactions per second to stay within the partner rate limit
5. THE `PartnerAPIError` enum SHALL provide a `userMessage` computed property returning a user-friendly description for each error case, suitable for display in the tvOS UI

### Requirement 10: Private API Deprecation and Cleanup

**User Story:** As a developer, I want to remove all private API code, so that the codebase only contains supported, maintainable API integrations.

#### Acceptance Criteria

1. THE codebase SHALL NOT contain any references to `api.ring.com/clients_api` endpoints after migration is complete
2. THE codebase SHALL NOT contain the `ring_official_ios` client ID or any email/password-based authentication code after migration is complete
3. THE `DevicesWrapper` struct (which parses the private API's grouped device response format) SHALL be deleted and replaced with a JSON:API parser
4. THE `RingDeviceResponse` model SHALL be replaced with a Partner API-specific DTO that maps JSON:API `data` resources to the domain `RingDevice` model
5. THE `RingEventResponse` model SHALL be replaced with a Partner API-specific DTO that maps the Partner API event format to the domain `RingEvent` model
6. THE `StreamSessionResponse` model (which captures SIP session parameters) SHALL be deleted, as WHEP sessions do not use SIP parameters
7. THE `RingAPIError` enum SHALL be replaced by the `PartnerAPIError` enum, removing private-API-specific cases (`twoFactorRequired`, `twoFactorInvalid`, `noSnapshotAvailable`) and adding Partner API-specific cases

### Requirement 11: Domain Model Adaptation

**User Story:** As a developer, I want the domain models to accurately represent Partner API data, so that the app correctly handles string device IDs and new response formats.

#### Acceptance Criteria

1. THE `RingDevice` model SHALL use a `String` type for its `id` property (the Partner API uses string device identifiers, not integers)
2. THE `RingDevice` model SHALL include a `powerSource` property (battery or line-powered) parsed from the Partner API device attributes, as this determines the Session_Duration_Limit
3. THE `RingEvent` model SHALL use a `String` type for its `id` and `deviceId` properties to match the Partner API's string identifiers
4. THE `StreamSession` model SHALL be updated to remove all SIP-related fields (`sipServerIp`, `sipServerPort`, `sipSessionId`) and instead store the WHEP session resource URL and the device's Session_Duration_Limit
5. THE `AuthToken` model SHALL include the `client_id` scope information if provided by the Partner API token response, while retaining `accessToken`, `refreshToken`, and `expiresAt`
