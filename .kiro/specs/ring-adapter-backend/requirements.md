# Requirements Document

## Introduction

This document specifies the requirements for transforming the existing `partner-auth-backend` service into a pluggable adapter-based backend that can serve the tvOS app either from mock data (current behavior) or from the user's real Ring account via Ring's unofficial consumer API. The motivation is pragmatic: the tvOS client is fully implemented, but Ring Partner API approval is a multi-week process. By introducing a `RingAdapter` abstraction with a `MockRingAdapter` (current behavior) and a new `UnofficialRingAdapter` (backed by the user's personal Ring refresh token), a developer can exercise the tvOS app against real cameras on their own account today, while the Partner API OAuth code paths remain in place for later use.

The tvOS app is intentionally unaware of which adapter is active. All existing `/mock/*` endpoints continue to serve as the application's public surface; only the backend's internal implementation changes based on the configured adapter. Selection is controlled by a single environment variable, `RING_ADAPTER`, with mock mode remaining the default.

The most substantial technical challenge is live streaming. Ring's unofficial consumer API does not speak WHEP. Instead, it uses a proprietary SIP-over-WebSocket signaling protocol to negotiate RTP streams (as implemented by the `ring-client-api` Node.js library). To preserve the tvOS app's existing WHEP contract, the backend must bridge between Ring's SIP session and the local `mediamtx` instance, republishing Ring's H.264/Opus RTP as RTSP so that `mediamtx` can serve WHEP to the app unchanged. This video bridge is a first-class requirement and accounts for most of the implementation scope.

Security is critical because the Ring refresh token grants full read access to the user's Ring account. The token must never be logged, must be stored encrypted at rest using the existing `FernetEncryptor`, must be loaded from an environment variable on startup, and must be updated in place whenever Ring rotates it in a token response. Rate limiting on upstream Ring calls is required to avoid triggering account-level blocks.

Out of scope for this spec (documented here for clarity): the 2FA bootstrap flow used to generate the refresh token (users run `npx -p ring-client-api ring-auth-cli` externally), multi-user support (single-user personal use only), and production deployment beyond local Docker Compose.

## Glossary

- **Ring_Adapter**: An abstract interface defining the operations required to serve the tvOS app's device, event, media, and streaming endpoints. All implementations of this interface are interchangeable behind the existing `/mock/*` HTTP surface.
- **Mock_Ring_Adapter**: The implementation of `Ring_Adapter` that returns hardcoded device data and proxies WHEP requests to the local `mediamtx` test pattern. Equivalent to the backend's current behavior.
- **Unofficial_Ring_Adapter**: The implementation of `Ring_Adapter` that calls Ring's unofficial consumer API (the one exercised by the `ring-client-api` library) using the user's personal Ring refresh token.
- **Ring_Consumer_API**: Ring's unofficial, undocumented HTTPS API at `https://api.ring.com` used by the Ring mobile app and the `ring-client-api` library. Not to be confused with the official Ring Partner API.
- **Ring_Refresh_Token**: A long-lived token issued by Ring's consumer OAuth server that the backend exchanges for short-lived access tokens. Generated externally by the user via `ring-auth-cli` and supplied to the backend via the `RING_REFRESH_TOKEN` environment variable.
- **Ring_Access_Token**: A short-lived bearer token obtained by exchanging the `Ring_Refresh_Token` at Ring's consumer OAuth endpoint. Used as the `Authorization: Bearer` header on subsequent Ring consumer API calls.
- **Refresh_Token_Store**: The persistence layer (SQLite via the existing backend database) that holds the current Ring refresh token, encrypted at rest using `FernetEncryptor`. Updated whenever Ring returns a new refresh token.
- **Video_Bridge**: The backend component that negotiates a Ring SIP session on the user's behalf, receives H.264/Opus RTP from Ring, and republishes the media as RTSP to the local `mediamtx` instance at `rtsp://mediamtx:8554/ring/{device_id}`.
- **Ring_SIP_Session**: A session established with Ring's streaming infrastructure using SIP-over-WebSocket signaling, as defined by Ring's unofficial streaming protocol and implemented by `ring-client-api`.
- **mediamtx**: The existing media server (already present in `docker-compose.yml`) that accepts RTSP input and serves WHEP output to the tvOS app.
- **WHEP**: WebRTC-HTTP Egress Protocol; the HTTP-based signaling flow the tvOS app uses to subscribe to live video via `POST .../whep/sessions`.
- **Adapter_Mode**: The runtime selection of a `Ring_Adapter` implementation, controlled by the `RING_ADAPTER` environment variable. Valid values are `mock` (default) and `unofficial`.
- **Mock_Route_Surface**: The set of HTTP endpoints under the `/mock/*` path prefix that the tvOS app consumes. The adapter lives behind this surface; the paths are unchanged regardless of `Adapter_Mode`.
- **Fernet_Encryptor**: The existing backend component (in `partner-auth-backend/app/data/`) that provides symmetric encryption for secrets stored in SQLite, keyed by the `TOKEN_ENCRYPTION_KEY` environment variable.
- **Rate_Limit_Governor**: The backend component that bounds the rate of outbound HTTP requests to the Ring consumer API to prevent Ring from blocking the user's account or IP address.
- **Stream_Session**: A logical live-streaming session that binds a tvOS WHEP session to a Ring SIP session and the corresponding `mediamtx` RTSP path. Identified by a backend-generated `session_id`.

## Requirements

### Requirement 1: Ring Adapter Abstraction

**User Story:** As a backend developer, I want a single `Ring_Adapter` interface that defines every operation the tvOS app depends on, so that mock and real-Ring implementations are interchangeable and new backends can be added without modifying the route layer.

#### Acceptance Criteria

1. THE Ring_Adapter SHALL define an asynchronous operation `list_devices()` that returns the user's Ring devices in the JSON:API-compatible shape currently returned by the `GET /mock/devices` endpoint.
2. THE Ring_Adapter SHALL define an asynchronous operation `list_events(device_id, limit)` that returns the event history for a device in the shape currently returned by the `GET /mock/history/devices/{device_id}/events` endpoint.
3. THE Ring_Adapter SHALL define an asynchronous operation `download_snapshot(device_id)` that returns an image byte payload and content-type in the shape currently returned by the `POST /mock/devices/{device_id}/media/image/download` endpoint.
4. THE Ring_Adapter SHALL define an asynchronous operation `download_video(device_id, event_id)` that returns a playable clip URL in the shape currently returned by the `POST /mock/devices/{device_id}/media/video/download` endpoint.
5. THE Ring_Adapter SHALL define an asynchronous operation `create_stream_session(device_id, sdp_offer)` that returns an SDP answer, a `Location` header value, and a backend-generated session identifier in the shape currently returned by the `POST /mock/devices/{device_id}/media/streaming/whep/sessions` endpoint.
6. THE Ring_Adapter SHALL define an asynchronous operation `delete_stream_session(session_id)` that terminates the session in the shape currently returned by the `DELETE /mock/session/{session_id}` endpoint.
7. THE Ring_Adapter SHALL define a synchronous operation `mode()` that returns a stable string identifier for the adapter implementation (e.g., `"mock"` or `"unofficial"`) for use in logging and diagnostics.
8. THE Ring_Adapter SHALL raise an adapter-specific error type, distinct from HTTP exceptions, when an upstream operation fails, so that the route layer can map adapter errors to HTTP status codes in one place.

### Requirement 2: Mock Ring Adapter Implementation

**User Story:** As a developer running the stack without Ring credentials, I want the mock adapter to preserve every behavior of the current backend, so that CI, offline development, and demos continue to work exactly as they do today.

#### Acceptance Criteria

1. THE Mock_Ring_Adapter SHALL return the same four hardcoded devices (`device_front_door`, `device_backyard`, `device_garage`, `device_indoor`) currently served by `GET /mock/devices`, with identical attributes.
2. WHEN `list_events(device_id, limit)` is invoked, THE Mock_Ring_Adapter SHALL generate the same synthetic event history currently produced by the `_generate_mock_events` helper, capped at the requested limit.
3. WHEN `download_snapshot(device_id)` is invoked, THE Mock_Ring_Adapter SHALL return the same placeholder PNG payload currently served by `POST /mock/devices/{device_id}/media/image/download`.
4. WHEN `download_video(device_id, event_id)` is invoked, THE Mock_Ring_Adapter SHALL return the same Apple HLS test stream URL currently served by `POST /mock/devices/{device_id}/media/video/download`.
5. WHEN `create_stream_session(device_id, sdp_offer)` is invoked, THE Mock_Ring_Adapter SHALL forward the SDP offer to the `mediamtx` WHEP endpoint configured by `MEDIAMTX_WHEP_URL` and return the SDP answer received from `mediamtx`.
6. IF `mediamtx` is unreachable when `create_stream_session` is invoked, THEN THE Mock_Ring_Adapter SHALL return the same stub SDP answer currently produced by the mock route, so that the fallback behavior is unchanged.
7. WHEN `delete_stream_session(session_id)` is invoked, THE Mock_Ring_Adapter SHALL acknowledge the request without calling any external service, matching the current mock route behavior.
8. THE Mock_Ring_Adapter SHALL require no Ring credentials, no refresh token, and no outbound calls to Ring-owned hosts for any operation.

### Requirement 3: Unofficial Ring Adapter — Authentication

**User Story:** As a developer with a personal Ring account, I want the unofficial adapter to authenticate to Ring using a long-lived refresh token, so that the backend can make API calls without embedding my password and without requiring repeated 2FA prompts.

#### Acceptance Criteria

1. WHEN the Adapter_Mode is `unofficial` and no refresh token is present in the Refresh_Token_Store at startup, THE Unofficial_Ring_Adapter SHALL read the refresh token from the `RING_REFRESH_TOKEN` environment variable and persist the value to the Refresh_Token_Store encrypted with the Fernet_Encryptor.
2. WHEN the Adapter_Mode is `unofficial` and a refresh token is already present in the Refresh_Token_Store at startup, THE Unofficial_Ring_Adapter SHALL use the stored value in preference to the `RING_REFRESH_TOKEN` environment variable so that a previously rotated token is not overwritten by a stale bootstrap value.
3. WHEN a Ring consumer API call requires an access token, THE Unofficial_Ring_Adapter SHALL exchange the current refresh token for a new access token by sending a POST request to Ring's consumer OAuth endpoint with `grant_type=refresh_token` and the stored refresh token.
4. WHEN an access token is obtained, THE Unofficial_Ring_Adapter SHALL cache the access token in memory until 60 seconds before its expiry, reusing it across requests.
5. WHEN a Ring consumer OAuth response includes a new refresh token, THE Unofficial_Ring_Adapter SHALL replace the value in the Refresh_Token_Store with the new refresh token encrypted with the Fernet_Encryptor, and SHALL log the rotation event without logging either token value.
6. IF the Adapter_Mode is `unofficial` and neither the `RING_REFRESH_TOKEN` environment variable nor the Refresh_Token_Store contains a refresh token at startup, THEN THE backend SHALL fail startup with an error message that names the missing source and SHALL NOT start the HTTP server.
7. IF a refresh token exchange returns HTTP 401 from Ring, THEN THE Unofficial_Ring_Adapter SHALL log an authentication failure event, mark the stored refresh token as invalid in the Refresh_Token_Store, and return an adapter error indicating that user intervention is required to regenerate the refresh token.
8. THE Unofficial_Ring_Adapter SHALL NOT log, emit in error responses, or include in diagnostics the plaintext value of the refresh token or any access token.

### Requirement 4: Unofficial Ring Adapter — Devices and Events

**User Story:** As a tvOS app user, I want the device list and event history in the app to reflect my real Ring account, so that I see my actual cameras and their real motion and doorbell events.

#### Acceptance Criteria

1. WHEN `list_devices()` is invoked on the Unofficial_Ring_Adapter, THE adapter SHALL call the Ring consumer API devices endpoint, map the response to the JSON:API shape defined by `Ring_Adapter.list_devices()`, and return the list of the authenticated user's cameras and doorbells.
2. THE Unofficial_Ring_Adapter SHALL map each Ring consumer API device to the JSON:API resource shape with `id` set to the Ring device identifier as a string, `type` set to the Ring device kind, and `attributes` containing at minimum `name`, `model`, `firmware_version`, `power_source`, and `status` fields compatible with the mock adapter's output.
3. WHEN `list_events(device_id, limit)` is invoked on the Unofficial_Ring_Adapter, THE adapter SHALL call the Ring consumer API history endpoint for the specified device and return up to `limit` events in the same event shape produced by the Mock_Ring_Adapter.
4. THE Unofficial_Ring_Adapter SHALL map each Ring consumer API event to the event shape with `id`, `device_id`, `type` (one of the tvOS-recognized event types such as `motion` or `ding`), `created_at` as ISO 8601, and `duration` in seconds where available.
5. IF `list_events` is invoked for a device identifier that does not belong to the authenticated user, THEN THE Unofficial_Ring_Adapter SHALL return an adapter error that the route layer maps to HTTP 404.
6. WHEN a Ring consumer API response is received for any device or event operation, THE Unofficial_Ring_Adapter SHALL apply response caching with a maximum age of 30 seconds for device lists and 10 seconds for event lists to reduce upstream call volume.

### Requirement 5: Unofficial Ring Adapter — Snapshots and Clips

**User Story:** As a tvOS app user, I want to view the current snapshot and recorded clips from my real Ring cameras, so that I can see what happened at my door without opening the official Ring app.

#### Acceptance Criteria

1. WHEN `download_snapshot(device_id)` is invoked on the Unofficial_Ring_Adapter, THE adapter SHALL request a current snapshot image from the Ring consumer API snapshot endpoint for the device and return the JPEG or PNG bytes along with the correct content type.
2. IF Ring returns HTTP 404 or an equivalent "snapshot not available" response when `download_snapshot` is invoked, THEN THE Unofficial_Ring_Adapter SHALL return an adapter error that the route layer maps to HTTP 503 with a retriable error code.
3. WHEN `download_video(device_id, event_id)` is invoked on the Unofficial_Ring_Adapter, THE adapter SHALL call the Ring consumer API clip download endpoint for the specified event and return a playable clip URL in the same response shape produced by the Mock_Ring_Adapter.
4. IF the authenticated Ring user's subscription does not include clip download access (Ring Protect not active) and `download_video` is invoked, THEN THE Unofficial_Ring_Adapter SHALL return an adapter error that the route layer maps to HTTP 402 with a descriptive error code indicating a subscription is required.
5. THE Unofficial_Ring_Adapter SHALL NOT cache snapshot or clip URLs beyond a single request, because Ring clip URLs are short-lived and pre-signed.

### Requirement 6: Video Bridge — SIP to RTSP

**User Story:** As a tvOS app user, I want live WebRTC streaming from my real Ring cameras to work through the existing WHEP endpoint, so that the tvOS app code does not need to change to support real cameras.

#### Acceptance Criteria

1. WHEN `create_stream_session(device_id, sdp_offer)` is invoked on the Unofficial_Ring_Adapter, THE adapter SHALL initiate a Ring SIP session for the specified device using the Ring unofficial streaming signaling protocol and obtain Ring's RTP endpoints for the device's audio and video streams.
2. WHEN a Ring SIP session is established, THE Video_Bridge SHALL receive the H.264 video RTP stream and the Opus audio RTP stream from Ring and republish them as a single RTSP stream to the local `mediamtx` instance at the path `rtsp://mediamtx:8554/ring/{device_id}`.
3. WHEN the RTSP stream is available in `mediamtx`, THE Unofficial_Ring_Adapter SHALL forward the tvOS app's SDP offer to `mediamtx`'s WHEP endpoint for the `ring/{device_id}` path and return the SDP answer, the `Location` header value, and a backend-generated `session_id` in the same response shape produced by the Mock_Ring_Adapter.
4. THE Unofficial_Ring_Adapter SHALL maintain a mapping from backend-generated `session_id` values to Ring SIP sessions and `mediamtx` RTSP paths for the lifetime of each stream session.
5. WHEN `delete_stream_session(session_id)` is invoked on the Unofficial_Ring_Adapter, THE adapter SHALL terminate the Ring SIP session bound to that `session_id`, stop the RTSP publish to `mediamtx`, and remove the session from the session mapping.
6. WHEN a Ring SIP session is terminated by Ring (camera offline, network interruption, or upstream timeout) before the tvOS app ends the stream, THE Video_Bridge SHALL stop the corresponding RTSP publish within 5 seconds and mark the session as terminated in the session mapping.
7. IF `create_stream_session` is invoked while the maximum number of concurrent Ring SIP sessions (configurable via `RING_MAX_CONCURRENT_STREAMS`, default 2) is already active, THEN THE Unofficial_Ring_Adapter SHALL return an adapter error that the route layer maps to HTTP 429 with a retriable error code.
8. THE Video_Bridge SHALL tolerate the absence of audio RTP from Ring (audio-only doorbells and video-only cameras) and republish to `mediamtx` with the audio track omitted when no audio is available.

### Requirement 7: Adapter Selection and Configuration

**User Story:** As a developer, I want to switch between mock and real-Ring modes with a single environment variable, so that I can toggle the backend's behavior without changing code or rebuilding containers.

#### Acceptance Criteria

1. THE backend SHALL read the `RING_ADAPTER` environment variable at startup, SHALL accept the values `mock` and `unofficial`, and SHALL treat a missing or empty value as `mock`.
2. IF the `RING_ADAPTER` environment variable is set to any value other than `mock` or `unofficial`, THEN THE backend SHALL fail startup with an error message that lists the accepted values and SHALL NOT start the HTTP server.
3. WHEN the backend starts, THE backend SHALL instantiate exactly one Ring_Adapter implementation corresponding to the configured Adapter_Mode and SHALL inject the same instance into every route handler that serves the `/mock/*` surface.
4. THE `/mock/*` HTTP path prefix, request shapes, and response shapes SHALL remain unchanged regardless of the configured Adapter_Mode, so that the tvOS app requires no changes to use either adapter.
5. WHEN the backend starts, THE backend SHALL log a single startup line that includes the configured Adapter_Mode, so that an operator can verify which adapter is active.
6. WHERE the Adapter_Mode is `unofficial`, THE backend SHALL read the `RING_REFRESH_TOKEN`, `RING_MAX_CONCURRENT_STREAMS`, `RING_API_RATE_LIMIT_PER_MINUTE`, and `MEDIAMTX_RTSP_URL` environment variables in addition to the existing required variables.
7. THE backend SHALL preserve the existing partner-API OAuth environment variables (`RING_CLIENT_ID`, `RING_CLIENT_SECRET`, `RING_HMAC_KEY`) as required configuration even when the Adapter_Mode is `mock` or `unofficial`, so that the partner-auth code paths remain startable for future use.
8. THE backend SHALL preserve the existing `APP_API_KEY` requirement and the API key check on the `GET /api/token` endpoint regardless of Adapter_Mode.

### Requirement 8: Rate Limiting and Upstream Hygiene

**User Story:** As a developer, I want the backend to bound outbound traffic to Ring's consumer API, so that my personal Ring account is not rate-limited or blocked by Ring's abuse detection.

#### Acceptance Criteria

1. THE Rate_Limit_Governor SHALL enforce a ceiling of at most `RING_API_RATE_LIMIT_PER_MINUTE` outbound HTTP requests per rolling 60-second window to Ring-owned hosts, with a default value of 60.
2. WHEN the Rate_Limit_Governor ceiling is reached, THE Unofficial_Ring_Adapter SHALL queue new outbound requests for up to 5 seconds before returning an adapter error that the route layer maps to HTTP 503 with a retriable error code.
3. WHEN Ring returns an HTTP 429 response on any outbound call, THE Unofficial_Ring_Adapter SHALL honor the `Retry-After` header if present and SHALL apply exponential backoff with a 1-second initial delay, doubling up to a 30-second cap, when the header is absent.
4. WHEN Ring returns an HTTP 5xx response on any outbound call, THE Unofficial_Ring_Adapter SHALL retry the request up to 2 times with exponential backoff before returning an adapter error.
5. THE Unofficial_Ring_Adapter SHALL set a per-request timeout of 10 seconds on all Ring consumer API HTTPS calls, excluding long-lived SIP and RTP connections used by the Video_Bridge.
6. THE Unofficial_Ring_Adapter SHALL send a stable, identifying `User-Agent` HTTP header on all Ring consumer API requests that reflects the backend's name and version.

### Requirement 9: Security

**User Story:** As a developer storing a high-value Ring credential, I want the refresh token protected against every plausible leak vector, so that accidental logging, repository commits, or storage compromise do not expose my Ring account.

#### Acceptance Criteria

1. THE Refresh_Token_Store SHALL persist the Ring refresh token only in encrypted form using the Fernet_Encryptor keyed by the `TOKEN_ENCRYPTION_KEY` environment variable.
2. THE backend SHALL NOT write the plaintext refresh token, access token, or Ring session cookies to any log destination, error response, diagnostic endpoint, or exception message.
3. THE `.env.example` file SHALL document `RING_REFRESH_TOKEN` with a placeholder value and an explanatory comment, and SHALL NOT contain a real refresh token.
4. THE `.gitignore` file SHALL include the `.env` path under `partner-auth-backend/` so that a populated `.env` is not tracked by git.
5. IF a log record is emitted that contains any field named `refresh_token`, `access_token`, or `authorization`, THEN THE backend's log formatter SHALL redact the field value to the literal string `[REDACTED]` before the record is written.
6. THE backend SHALL load the `RING_REFRESH_TOKEN` value from the environment at startup only, and SHALL NOT re-read the environment variable during request handling.
7. WHEN the Unofficial_Ring_Adapter rotates the refresh token in the Refresh_Token_Store, THE backend SHALL write the new ciphertext using a single atomic database transaction so that a crash cannot leave the store in a half-updated state.

### Requirement 10: Docker Compose Integration

**User Story:** As a developer, I want `docker compose up` to start the backend in whichever adapter mode I configure, so that switching between mock and real-Ring modes is a one-line change to `.env`.

#### Acceptance Criteria

1. THE `docker-compose.yml` file SHALL declare the `backend` service's environment with the new `RING_ADAPTER`, `RING_REFRESH_TOKEN`, `RING_MAX_CONCURRENT_STREAMS`, `RING_API_RATE_LIMIT_PER_MINUTE`, and `MEDIAMTX_RTSP_URL` variables, with defaults appropriate for mock mode and the unofficial variables defaulting to values sourced from the shell environment or `.env` file.
2. THE `backend` service SHALL be able to reach the `mediamtx` service at the hostname `mediamtx` on ports 8554 (RTSP) and 8889 (WHEP) via the default Docker Compose network, unchanged from the current stack.
3. WHEN the Adapter_Mode is `unofficial`, THE `backend` service SHALL publish its Video_Bridge RTSP output to `mediamtx` using the `MEDIAMTX_RTSP_URL` value, with a default of `rtsp://mediamtx:8554/ring`.
4. WHERE the Adapter_Mode is `unofficial`, THE `ffmpeg` test-pattern service SHALL be optional and SHALL be placed in a Docker Compose profile named `mock` so that `docker compose --profile mock up` starts the full mock stack and the default `docker compose up` omits the test pattern.
5. THE `partner-auth-backend/.env.example` file SHALL include every new environment variable introduced by this spec with placeholder values and explanatory comments.
6. WHEN the `backend` container starts with `RING_ADAPTER=unofficial` and `RING_REFRESH_TOKEN` unset, THE backend SHALL exit with a non-zero status code within 5 seconds so that `docker compose up` surfaces the misconfiguration quickly.

### Requirement 11: Observability and Error Mapping

**User Story:** As a developer debugging the stack, I want clear, consistent logs and HTTP error codes from every adapter operation, so that I can tell within seconds whether a failure is upstream (Ring), internal (backend), or configuration (missing env var).

#### Acceptance Criteria

1. WHEN an adapter operation is invoked, THE backend SHALL emit a structured log record containing the `request_id`, the adapter `mode()`, the operation name, the `device_id` (where applicable), and the outcome (`ok`, `upstream_error`, `adapter_error`, or `timeout`).
2. WHEN an adapter operation returns an adapter error, THE route layer SHALL map the error to a stable HTTP status code and response body shape, with the mapping defined in one place so that every `/mock/*` endpoint produces consistent error responses.
3. THE backend SHALL return a response body of the shape `{"error": "<stable_error_code>"}` for every adapter-originated error, without exposing upstream Ring error messages, stack traces, or internal file paths.
4. WHEN a Ring SIP session is established, maintained, or terminated by the Video_Bridge, THE backend SHALL emit a structured log record containing the `session_id`, `device_id`, adapter `mode()`, and the event type (`sip_established`, `sip_terminated`, `rtsp_publish_started`, `rtsp_publish_stopped`).
5. THE backend SHALL include the adapter `mode()` in the response body of the existing `GET /health` endpoint so that an operator can verify the running configuration without reading logs.
6. THE backend SHALL expose a `GET /health/adapter` endpoint that returns HTTP 200 with a body describing the adapter mode, the refresh token validity flag (when the Unofficial_Ring_Adapter is active), the count of active stream sessions, and the current Ring API request rate, and SHALL require the existing API key on this endpoint.

### Requirement 12: Compatibility with Existing Partner-Auth Code

**User Story:** As a developer, I want the existing partner-API OAuth, HMAC webhook, and account-link code to remain in place and importable, so that when Ring Partner API approval arrives I can add a third `PartnerApiRingAdapter` without rewriting the backend.

#### Acceptance Criteria

1. THE existing modules `app/routes/ring_callbacks.py`, `app/routes/app_api.py`, and the supporting services for OAuth token exchange, HMAC verification, and webhook handling SHALL remain present and importable regardless of the configured Adapter_Mode.
2. THE existing `/ring/token-exchange`, `/ring/account-link`, `/ring/webhook`, `/ring/app-homepage`, `/api/token`, and `/health` HTTP routes SHALL remain registered on the FastAPI application regardless of the configured Adapter_Mode.
3. WHEN the Adapter_Mode is `mock` or `unofficial`, THE partner-auth routes SHALL continue to respond as they do today, and SHALL NOT invoke the selected Ring_Adapter implementation.
4. THE Ring_Adapter interface and its `Mock_Ring_Adapter` and `Unofficial_Ring_Adapter` implementations SHALL reside in a new package (e.g., `app/adapters/`) distinct from the partner-auth modules, so that the two code paths remain separable for future refactoring.
5. THE existing `/mock/*` route handlers SHALL be refactored to delegate all business logic to the injected Ring_Adapter, so that adding a future `PartnerApiRingAdapter` requires only a new adapter implementation and a new value for `RING_ADAPTER`.

### Requirement 13: Testing Support

**User Story:** As a developer, I want every adapter and the Video_Bridge to be testable without calling Ring, so that the test suite stays fast, deterministic, and free of flakiness caused by upstream dependencies.

#### Acceptance Criteria

1. THE Ring_Adapter interface SHALL be defined so that a fake implementation can be constructed in a test fixture and injected into route handlers without starting any external service.
2. THE Unofficial_Ring_Adapter SHALL accept an HTTP client dependency at construction time so that tests can substitute a mocked client that returns recorded Ring consumer API responses.
3. THE Video_Bridge SHALL accept its RTSP publishing target and SIP signaling client as construction-time dependencies so that tests can substitute fakes for both.
4. THE backend SHALL include a test that starts the FastAPI app with `RING_ADAPTER=mock` and verifies that all six `/mock/*` endpoints respond with the current hardcoded mock payloads, proving no behavioral regression.
5. THE backend SHALL include a test that starts the FastAPI app with `RING_ADAPTER=unofficial` using an injected fake Ring HTTP client and fake SIP signaling client, and verifies that each adapter operation maps fake upstream responses to the correct `/mock/*` response shape.
6. THE backend SHALL include a test that verifies refresh token rotation: given a fake OAuth response containing a new refresh token, the Refresh_Token_Store is updated to the new encrypted value and the previous value is no longer retrievable.
