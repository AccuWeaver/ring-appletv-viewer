# Requirements Document

## Introduction

This spec defines how the `partner-auth-backend` / `ring-adapter-backend` service delivers **real live video and real camera snapshots** to the tvOS client end-to-end. It builds on the existing `ring-adapter-backend` spec (which defines the `Ring_Adapter` ABC, the `Mock_Ring_Adapter`, the `Unofficial_Ring_Adapter`, and the SIP→RTSP `Video_Bridge`) and on the `ring-partner-api-migration` spec (which defines the Partner API's WHEP, snapshot, and clip contracts).

The operational intent is simple: when the tvOS app asks for a device's live stream or current snapshot, the backend must serve media sourced from a real Ring account — either from the Ring Partner API (once partner approval lands) or from the unofficial consumer API already in use by the backend for snapshot fetch and refresh. The existing in-memory mock data (hardcoded devices, placeholder PNG, Apple HLS test stream, local `mediamtx` test pattern) remains only as a last-resort fallback when no real source is configured or when a configured real source is unavailable and no other real source is reachable.

This spec adds three things on top of `ring-adapter-backend`:

1. A third adapter, `Partner_Ring_Adapter`, that wraps the Partner API's WHEP and media endpoints and is selectable alongside `mock` and `unofficial`.
2. A **Source_Router** that, per operation, selects the configured real source first, degrades to a documented fallback class only on explicit failure, and never silently substitutes mock data when a real source is configured and healthy.
3. A **Snapshot_Cache** that the backend refreshes on a schedule from the active real source so that snapshot responses to the tvOS client are served from a fresh, real image without blocking on a live upstream fetch on every request.

The tvOS client contract is unchanged. All endpoints under `/mock/*` retain their paths, request shapes, and response shapes. The client cannot tell which source produced a given response, which is the property that lets the backend flip between Partner, Unofficial, and Mock without any client change.

Out of scope: changes to the tvOS client, Ring Partner approval or onboarding, the 2FA bootstrap that produces the unofficial refresh token, multi-tenant operation, and production deployment beyond local Docker Compose.

## Glossary

- **Ring_Adapter**: The abstract interface defined by the `ring-adapter-backend` spec. Every real-source and mock implementation exposes the same operations (`list_devices`, `list_events`, `download_snapshot`, `download_video`, `create_stream_session`, `delete_stream_session`, `mode`).
- **Mock_Ring_Adapter**: Implementation defined by the `ring-adapter-backend` spec that returns hardcoded devices, placeholder snapshot PNG, Apple HLS test URL, and `mediamtx` test-pattern WHEP. Represents synthetic, non-real data.
- **Unofficial_Ring_Adapter**: Implementation defined by the `ring-adapter-backend` spec that calls the Ring consumer API at `api.ring.com` using a personal refresh token, and uses the `Video_Bridge` to republish Ring SIP/RTP media as RTSP to `mediamtx`.
- **Partner_Ring_Adapter**: A new implementation of `Ring_Adapter`, introduced by this spec, that calls the Ring Partner API at `https://api.amazonvision.com/v1` for devices, events, snapshots, clip download, and WHEP streaming, using the OAuth access token obtained through the partner device-authorization or account-link flow.
- **Source**: A concrete `Ring_Adapter` implementation. Exactly one Source is designated the `Active_Source` per operation at any given time.
- **Real_Source**: A Source that reads media and state from a Ring-owned backend. `Partner_Ring_Adapter` and `Unofficial_Ring_Adapter` are Real_Sources. `Mock_Ring_Adapter` is not.
- **Source_Router**: The new backend component that selects the Active_Source for each `Ring_Adapter` operation based on configuration, per-source health, and the failure class returned by the previously attempted Source.
- **Adapter_Mode**: The configured mode string for a Source, one of `mock`, `unofficial`, `partner`. Read from the `RING_ADAPTER` environment variable at startup.
- **Routing_Profile**: The configured ordered list of Sources the Source_Router may attempt for a given request, read at startup from the `RING_ADAPTER_ROUTING` environment variable. The first entry is the primary Source; later entries are eligible fallbacks.
- **Failure_Class**: The category assigned by a Source to an operation failure: `configuration`, `authentication`, `upstream_unavailable`, `upstream_timeout`, `not_found`, `subscription_required`, `rate_limited`, `capacity_exceeded`, `snapshot_unavailable`, or `internal`.
- **Fallback_Eligible_Class**: A Failure_Class that the Source_Router is permitted to retry on the next Source in the Routing_Profile. Exactly: `upstream_unavailable`, `upstream_timeout`, and, for snapshot operations only, `snapshot_unavailable`.
- **Non_Fallback_Class**: Any Failure_Class that is not Fallback_Eligible. The Source_Router returns these directly to the client without attempting another Source.
- **Live_Media_Path**: The aggregate of the two operations `create_stream_session` (WHEP) and `download_snapshot` (still image) and the supporting Snapshot_Cache refresh job. The subject of the "always show real data" guarantee.
- **WHEP**: WebRTC-HTTP Egress Protocol. The signaling flow the tvOS app uses via `POST /mock/devices/{device_id}/media/streaming/whep/sessions` and `DELETE /mock/session/{session_id}`.
- **Partner_WHEP_Endpoint**: The Partner API WHEP session-creation endpoint at `https://api.amazonvision.com/v1/devices/{device_id}/media/streaming/whep/sessions`, which accepts an SDP offer and returns an SDP answer plus a `Location` session resource URL.
- **Unofficial_Stream_Pipeline**: The SIP→RTSP→WHEP pipeline defined by the `ring-adapter-backend` spec's `Video_Bridge`: the `Unofficial_Ring_Adapter` negotiates a SIP session with Ring via the `ring-sip-bridge` sidecar, the sidecar republishes RTP to `rtsp://mediamtx:8554/ring/{device_id}`, and the backend forwards the tvOS app's WHEP offer to `mediamtx`'s WHEP endpoint for that path.
- **Session_Map**: The backend data structure (defined by `ring-adapter-backend` as `StreamSessionMap`) that binds a backend-generated `session_id` to the Source that originated the session and to any Source-specific session handles (Partner session resource URL, or unofficial `bridge_session_id` plus `mediamtx` path).
- **Snapshot_Cache**: A new in-process per-device cache of the most recent real snapshot bytes, content type, fetch timestamp, and originating Source mode, with a configurable TTL.
- **Snapshot_Refresh_Job**: A backend-scheduled task that, for each known device from the Active_Source for `list_devices`, requests a fresh snapshot from the Active_Source for `download_snapshot` and writes the result to the Snapshot_Cache.
- **TTL_Fresh**: The maximum age at which a Snapshot_Cache entry is considered fresh, in seconds, configurable via `SNAPSHOT_TTL_FRESH_SECONDS`.
- **TTL_Stale_Serve**: The maximum age at which a Snapshot_Cache entry is still served to the client when every Real_Source is failing, in seconds, configurable via `SNAPSHOT_TTL_STALE_SERVE_SECONDS`.
- **Health_State**: Per-Source state tracked by the Source_Router: `up` or `down`, plus a `last_success_at` timestamp per operation.
- **Source_Quarantine_Window**: The duration for which a Source is skipped by the Source_Router after a threshold of consecutive upstream failures, in seconds, configurable via `SOURCE_QUARANTINE_SECONDS`.
- **Mock_Route_Surface**: The set of HTTP routes under the `/mock/*` path prefix exposed to the tvOS app. Paths and payload shapes are invariant across all Adapter_Mode and Routing_Profile choices.
- **API_Key_Check**: The existing `APP_API_KEY`-based authentication already enforced on `GET /api/token` and other administrative routes.

## Requirements

### Requirement 1: Source Routing Policy

**User Story:** As a backend operator, I want a single configuration knob that controls which real source serves live media, and a deterministic, documented fallback policy, so that I know exactly which upstream produced any given response and can reason about behavior when one upstream fails.

#### Acceptance Criteria

1. THE Source_Router SHALL read the `RING_ADAPTER_ROUTING` environment variable at startup and SHALL parse its value as a comma-separated ordered list of Adapter_Mode tokens, applying ASCII-whitespace trimming to each token and ASCII-lowercase folding before comparison, with each resulting token drawn from the set `{partner, unofficial, mock}`.
2. IF `RING_ADAPTER_ROUTING` is unset, empty, or contains only ASCII whitespace, THEN THE Source_Router SHALL derive the Routing_Profile from the `RING_ADAPTER` variable by treating its trimmed, lowercased value as the single entry of the Routing_Profile.
3. IF the parsed Routing_Profile contains any token outside the set `{partner, unofficial, mock}` after trimming and lowercasing, contains any empty token (for example from consecutive, leading, or trailing commas), contains duplicate entries, or contains more than 3 tokens, THEN THE backend SHALL fail startup with an error message that names the offending environment variable and its value and SHALL NOT start the HTTP server.
4. WHEN the backend receives a request for an operation defined by Ring_Adapter, THE Source_Router SHALL attempt the operation against the first Source in the Routing_Profile whose Health_State for that operation is not `down`.
5. WHEN a Source returns a Fallback_Eligible_Class for an operation, THE Source_Router SHALL attempt the next Source in the Routing_Profile whose Health_State for that operation is not `down`, in Routing_Profile order, until a Source succeeds for the operation or every eligible Source in the Routing_Profile has been attempted for the current request.
6. WHEN a Source returns a Non_Fallback_Class, THE Source_Router SHALL return that failure to the client without attempting any further Source.
7. THE Source_Router SHALL NOT attempt a Source whose Adapter_Mode is `mock` for an operation in the Live_Media_Path unless `mock` is the only entry in the Routing_Profile or unless every Real_Source in the Routing_Profile has been attempted for this request and returned a Fallback_Eligible_Class.
8. WHEN the Source_Router returns a response to the client for a Ring_Adapter operation, THE Source_Router SHALL attach an `X-Ring-Source` response header whose value is the Adapter_Mode of the Source that produced the response, or, when every eligible Source in the Routing_Profile returned a Fallback_Eligible_Class for the request, the Adapter_Mode of the last Source attempted for that request.
9. THE Routing_Profile SHALL apply to all Ring_Adapter operations uniformly within a single backend process, and THE Source_Router SHALL NOT use a different ordering for different operations.
10. IF both `RING_ADAPTER_ROUTING` and `RING_ADAPTER` are unset, empty, or contain only ASCII whitespace at startup, THEN THE backend SHALL fail startup with an error message that names both variables and SHALL NOT start the HTTP server.
11. IF every Source in the Routing_Profile eligible for the current operation has been attempted in Routing_Profile order and each attempt returned a Fallback_Eligible_Class, THEN THE Source_Router SHALL return the Failure_Class of the last attempted Source to the client as the response outcome for that request.

### Requirement 2: Partner Ring Adapter — Live Video

**User Story:** As a tvOS app user whose backend is configured for the Partner API, I want the live stream to come from the Ring Partner API, so that once approval lands I see the supported live feed my device produces without any client change.

#### Acceptance Criteria

1. WHEN `create_stream_session(device_id, sdp_offer)` is invoked on THE Partner_Ring_Adapter, THE adapter SHALL issue an HTTP POST to the Partner_WHEP_Endpoint for the specified device with `Content-Type: application/sdp`, the client-supplied SDP offer as the request body, and the partner `Authorization: Bearer` access token obtained via the existing partner OAuth flow.
2. WHEN THE Partner API returns HTTP 201 with `Content-Type: application/sdp`, THE Partner_Ring_Adapter SHALL return the response body verbatim as the SDP answer, the `Location` header value as the WHEP session resource URL, and a backend-generated UUID as the `session_id`.
3. WHEN THE Partner_Ring_Adapter returns a successful stream session, THE adapter SHALL record in the Session_Map the tuple `(session_id, mode="partner", partner_session_url, device_id, created_at)`.
4. WHEN `delete_stream_session(session_id)` is invoked and the Session_Map entry for `session_id` has `mode="partner"`, THE Partner_Ring_Adapter SHALL send an HTTP DELETE to the stored `partner_session_url` with the partner Bearer access token, and SHALL remove the entry from the Session_Map whether or not the DELETE succeeds.
5. IF THE Partner API returns HTTP 401 on WHEP session creation, THEN THE Partner_Ring_Adapter SHALL classify the failure as `authentication` and SHALL NOT retry the request before returning to the Source_Router.
6. IF THE Partner API returns HTTP 403 or HTTP 404 on WHEP session creation, THEN THE Partner_Ring_Adapter SHALL classify the failure as `not_found` and SHALL NOT treat it as Fallback_Eligible.
7. IF THE Partner API returns HTTP 402 or a documented subscription-required error code on WHEP session creation, THEN THE Partner_Ring_Adapter SHALL classify the failure as `subscription_required` and SHALL NOT treat it as Fallback_Eligible.
8. IF THE Partner API returns HTTP 429 on WHEP session creation, THEN THE Partner_Ring_Adapter SHALL classify the failure as `rate_limited` and SHALL NOT treat it as Fallback_Eligible.
9. IF THE Partner API returns HTTP 5xx or the request fails with a network or timeout error on WHEP session creation, THEN THE Partner_Ring_Adapter SHALL classify the failure as `upstream_unavailable` or `upstream_timeout` respectively.
10. THE Partner_Ring_Adapter SHALL set a 10-second request timeout on WHEP session creation and a 5-second request timeout on WHEP session deletion.

### Requirement 3: Unofficial Ring Adapter — Live Video via SIP → RTSP → WHEP

**User Story:** As a tvOS app user whose backend is configured for the unofficial consumer API, I want the live stream to come from my real Ring cameras via the backend's SIP-to-RTSP bridge, so that I can see my real cameras before the Partner API path is available.

#### Acceptance Criteria

1. WHEN `create_stream_session(device_id, sdp_offer)` is invoked on THE Unofficial_Ring_Adapter, THE adapter SHALL drive the Unofficial_Stream_Pipeline as defined by the `ring-adapter-backend` spec: request a bridge session from `ring-sip-bridge`, wait for the sidecar to report RTSP publish established, then forward the client SDP offer to the local `mediamtx` WHEP endpoint for the path `ring/{device_id}` and return the SDP answer.
2. WHEN THE Unofficial_Ring_Adapter returns a successful stream session, THE adapter SHALL record in the Session_Map the tuple `(session_id, mode="unofficial", bridge_session_id, mediamtx_path, device_id, created_at)`.
3. WHEN `delete_stream_session(session_id)` is invoked and the Session_Map entry for `session_id` has `mode="unofficial"`, THE Unofficial_Ring_Adapter SHALL issue a DELETE to the `ring-sip-bridge` sidecar for the stored `bridge_session_id`, SHALL instruct `mediamtx` to stop the RTSP publish for the stored `mediamtx_path`, and SHALL remove the entry from the Session_Map whether or not either downstream call succeeds.
4. WHEN THE Unofficial_Stream_Pipeline reports that a Ring SIP session has been terminated by Ring before `delete_stream_session` is invoked for the corresponding `session_id`, THE Unofficial_Ring_Adapter SHALL stop the associated RTSP publish within 5 seconds and SHALL mark the Session_Map entry as terminated so that the next client `DELETE` is a no-op.
5. IF `create_stream_session` is invoked while the number of entries in the Session_Map with `mode="unofficial"` is greater than or equal to `RING_MAX_CONCURRENT_STREAMS`, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `capacity_exceeded` and SHALL NOT treat it as Fallback_Eligible.
6. IF THE `ring-sip-bridge` sidecar returns HTTP 5xx, fails to establish a SIP session within 15 seconds, or is unreachable, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `upstream_unavailable` or `upstream_timeout` respectively.
7. IF THE Ring consumer OAuth endpoint returns HTTP 401 at any point during `create_stream_session`, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `authentication` and SHALL NOT treat it as Fallback_Eligible.
8. THE Unofficial_Ring_Adapter SHALL support republishing to `mediamtx` with the audio track omitted when Ring does not provide an audio RTP stream for the device, as specified by the `ring-adapter-backend` spec.

### Requirement 4: Partner Ring Adapter — Snapshots and Clip Download

**User Story:** As a tvOS app user whose backend is configured for the Partner API, I want snapshots and recorded clips to come from the Partner API, so that the images and playback URLs reflect my real Ring account.

#### Acceptance Criteria

1. WHEN `download_snapshot(device_id)` is invoked on THE Partner_Ring_Adapter, THE adapter SHALL send an HTTP POST to `https://api.amazonvision.com/v1/devices/{device_id}/media/image/download` with the partner Bearer access token and SHALL return the response body bytes together with the response `Content-Type` header value.
2. IF THE Partner API returns HTTP 404 or HTTP 204 or an equivalent "no snapshot available" response on snapshot download, THEN THE Partner_Ring_Adapter SHALL classify the failure as `snapshot_unavailable`.
3. IF THE Partner API returns HTTP 401 on snapshot download, THEN THE Partner_Ring_Adapter SHALL classify the failure as `authentication`.
4. IF THE Partner API returns HTTP 5xx or the request fails with a network or timeout error on snapshot download, THEN THE Partner_Ring_Adapter SHALL classify the failure as `upstream_unavailable` or `upstream_timeout` respectively.
5. WHEN `download_video(device_id, event_id)` is invoked on THE Partner_Ring_Adapter, THE adapter SHALL send an HTTP POST to `https://api.amazonvision.com/v1/devices/{device_id}/media/video/download` with the partner Bearer access token and the event identifier in the request body, and SHALL return the playable clip URL contained in the response in the response shape produced by the Mock_Ring_Adapter.
6. IF THE Partner API returns HTTP 402 or a documented subscription-required error code on clip download, THEN THE Partner_Ring_Adapter SHALL classify the failure as `subscription_required` and SHALL NOT treat it as Fallback_Eligible.
7. THE Partner_Ring_Adapter SHALL set a 10-second request timeout on snapshot and clip download.

### Requirement 5: Unofficial Ring Adapter — Snapshot Source Selection

**User Story:** As a tvOS app user whose backend is configured for the unofficial consumer API, I want snapshots to come from the real Ring consumer snapshot endpoint, so that the image I see is the most recent one Ring has for my camera.

#### Acceptance Criteria

1. WHEN `download_snapshot(device_id)` is invoked on THE Unofficial_Ring_Adapter, THE adapter SHALL request the most recent cached snapshot image from the Ring consumer snapshot endpoint for the specified device as defined by the `ring-adapter-backend` spec, with a request timeout of 10 seconds, and on HTTP 200 SHALL return the response body bytes verbatim together with the value of the response `Content-Type` header.
2. IF THE Ring consumer API returns HTTP 404, HTTP 204, or a documented "no snapshot available" response on snapshot fetch, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `snapshot_unavailable`.
3. IF THE Ring consumer API returns HTTP 429 on snapshot fetch, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `rate_limited` and SHALL honor the existing rate-limit and backoff behavior defined by the `ring-adapter-backend` spec.
4. THE Unofficial_Ring_Adapter SHALL NOT trigger a new camera-side snapshot capture as part of `download_snapshot`; it SHALL only request the most recent cached image.
5. IF THE Ring consumer API returns HTTP 401 on snapshot fetch, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `authentication` and SHALL NOT treat it as Fallback_Eligible.
6. IF THE Ring consumer API returns HTTP 5xx on snapshot fetch or the request fails with a network error, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `upstream_unavailable`, and IF the request exceeds the 10-second timeout defined in criterion 1, THEN THE Unofficial_Ring_Adapter SHALL classify the failure as `upstream_timeout`.

### Requirement 6: Snapshot Cache and Periodic Refresh

**User Story:** As a tvOS app user, I want the snapshot my app displays to be recent even when Ring rate-limits frequent requests, so that I do not see a stale or placeholder image and so the per-request path is fast.

#### Acceptance Criteria

1. THE Snapshot_Cache SHALL store, per device identifier, the most recently observed snapshot bytes, content type, fetch timestamp, and the Adapter_Mode of the Source that produced the bytes.
2. WHEN `download_snapshot(device_id)` is invoked on the Source_Router and the Snapshot_Cache contains an entry for `device_id` with age less than `SNAPSHOT_TTL_FRESH_SECONDS` (default 60), THE Source_Router SHALL return the cached bytes and content type without invoking any Source.
3. WHEN `download_snapshot(device_id)` is invoked on the Source_Router and the Snapshot_Cache does not contain an entry for `device_id` with age less than `SNAPSHOT_TTL_FRESH_SECONDS`, THE Source_Router SHALL invoke the Routing_Profile for the operation, and on success SHALL write the returned bytes, content type, current timestamp, and producing Adapter_Mode to the Snapshot_Cache before returning.
4. THE Snapshot_Refresh_Job SHALL run every `SNAPSHOT_REFRESH_INTERVAL_SECONDS` seconds (default 45) while the backend is running. IF a Snapshot_Refresh_Job cycle is still executing when the next scheduled cycle is due, THEN the scheduled cycle SHALL be skipped.
5. ON each execution, THE Snapshot_Refresh_Job SHALL obtain the current device list from the Active_Source for `list_devices` via the Source_Router and SHALL call the Source_Router's `download_snapshot` operation for each device in sequence with a per-device timeout of 10 seconds.
6. Snapshot_Refresh_Job invocations of `download_snapshot` via the Source_Router SHALL participate in the same quarantine accounting as client-initiated requests.
7. IF the Snapshot_Refresh_Job receives a `snapshot_unavailable` or `rate_limited` failure for a device, THEN THE Snapshot_Refresh_Job SHALL skip that device for the current cycle and SHALL NOT retry until the next scheduled cycle.
8. WHEN every Source in the Routing_Profile returns a Fallback_Eligible_Class on `download_snapshot`, THE Source_Router SHALL return the Snapshot_Cache entry for `device_id` provided the entry age is less than `SNAPSHOT_TTL_STALE_SERVE_SECONDS` (default 600), and SHALL return the Fallback_Eligible failure otherwise.
9. WHEN the Source_Router serves a Snapshot_Cache entry whose age is between `SNAPSHOT_TTL_FRESH_SECONDS` and `SNAPSHOT_TTL_STALE_SERVE_SECONDS`, THE Source_Router SHALL set the response header `X-Ring-Snapshot-Age` to the cache entry age in whole seconds.
10. WHEN the Source_Router serves a response from the Snapshot_Cache (either fresh or stale), THE `X-Ring-Source` response header SHALL be set to the Adapter_Mode stored in the cache entry that produced the snapshot bytes.
11. THE Snapshot_Cache SHALL bound its total memory footprint to `SNAPSHOT_CACHE_MAX_BYTES` (default 64 MiB) by evicting least-recently-used entries when the bound is exceeded.
12. THE Snapshot_Cache SHALL be stored in process memory only and SHALL NOT persist to disk.

### Requirement 7: "Always Show Real Data" Guarantee

**User Story:** As a backend operator, I want a guarantee that, when any Real_Source is configured and healthy, the tvOS client never receives mock media, so that real-account deployments cannot silently regress to placeholder content.

#### Acceptance Criteria

1. WHEN the Routing_Profile contains at least one Real_Source and at least one Real_Source in the profile has Health_State `up` at the time of a live-media request, THE Source_Router SHALL NOT produce a response from the Mock_Ring_Adapter for that request.
2. WHEN every Real_Source in the Routing_Profile has Health_State `down` and the Routing_Profile contains the `mock` Adapter_Mode as a later entry, THE Source_Router SHALL attempt the Mock_Ring_Adapter for operations in the Live_Media_Path only after each Real_Source in the profile has returned a Fallback_Eligible_Class for the current request.
3. WHEN the Source_Router serves a `create_stream_session` response produced by the Mock_Ring_Adapter while any Real_Source is configured in the Routing_Profile, THE Source_Router SHALL emit a WARNING-level structured log record with fields `event=live_media_fallback_to_mock`, the `device_id`, the attempted Source mode, the Failure_Class that triggered the fallback, and the `request_id`.
4. THE Source_Router SHALL NOT synthesize a Mock_Ring_Adapter snapshot response for `download_snapshot` while any Real_Source is configured; instead, THE Source_Router SHALL prefer the Snapshot_Cache stale-serve behavior defined in Requirement 6.7 and SHALL fall through to the Mock_Ring_Adapter only when both the Snapshot_Cache has no entry within `SNAPSHOT_TTL_STALE_SERVE_SECONDS` and every Real_Source has returned a Fallback_Eligible_Class.
5. WHEN the Routing_Profile contains only `mock`, THE Source_Router SHALL serve every operation from the Mock_Ring_Adapter without any of the above constraints.

### Requirement 8: Source Health and Quarantine

**User Story:** As a backend operator, I want a Source that has recently failed repeatedly to be skipped briefly so that ordinary requests are not delayed by retrying a clearly broken upstream, so that latency stays bounded during partial outages.

#### Acceptance Criteria

1. THE Source_Router SHALL maintain, per Source and per operation name, a rolling counter of consecutive failures whose Failure_Class is one of `upstream_unavailable` or `upstream_timeout`.
2. WHEN the rolling counter for a Source and operation reaches `SOURCE_QUARANTINE_THRESHOLD` (default 3), THE Source_Router SHALL mark the Source's Health_State as `down` for that operation and SHALL record a quarantine start timestamp.
3. WHILE a Source is quarantined for an operation and the time since quarantine start is less than `SOURCE_QUARANTINE_SECONDS` (default 60), THE Source_Router SHALL skip that Source for that operation and SHALL proceed to the next Source in the Routing_Profile as if the skipped Source had returned `upstream_unavailable`.
4. WHEN the quarantine duration for a Source and operation elapses, THE Source_Router SHALL mark the Source's Health_State for that operation as `up` and SHALL reset the rolling counter.
5. WHEN a Source succeeds on an operation, THE Source_Router SHALL reset the rolling counter for that Source and operation to zero and SHALL record `last_success_at` for that Source and operation as the current timestamp.
6. THE Source_Router SHALL NOT mark a Source `down` on a Non_Fallback_Class failure, because Non_Fallback_Class failures reflect request-specific or account-specific conditions rather than Source availability.

### Requirement 9: Configuration Surface

**User Story:** As a backend operator, I want the live-media routing, cache, and quarantine behavior to be configured through environment variables with safe defaults, so that I can tune the runtime without changing code.

#### Acceptance Criteria

1. THE backend SHALL read the following environment variables at startup and SHALL apply their values at the scope described: `RING_ADAPTER_ROUTING` (Routing_Profile), `RING_ADAPTER` (single-Source fallback source for Routing_Profile), `SNAPSHOT_TTL_FRESH_SECONDS`, `SNAPSHOT_TTL_STALE_SERVE_SECONDS`, `SNAPSHOT_REFRESH_INTERVAL_SECONDS`, `SNAPSHOT_CACHE_MAX_BYTES`, `SOURCE_QUARANTINE_THRESHOLD`, `SOURCE_QUARANTINE_SECONDS`, `RING_MAX_CONCURRENT_STREAMS` (maximum concurrent unofficial SIP sessions, default 2).
2. THE backend SHALL apply the following default values when the corresponding environment variables are unset: `SNAPSHOT_TTL_FRESH_SECONDS=60`, `SNAPSHOT_TTL_STALE_SERVE_SECONDS=600`, `SNAPSHOT_REFRESH_INTERVAL_SECONDS=45`, `SNAPSHOT_CACHE_MAX_BYTES=67108864`, `SOURCE_QUARANTINE_THRESHOLD=3`, `SOURCE_QUARANTINE_SECONDS=60`, `RING_MAX_CONCURRENT_STREAMS=2`.
3. IF `SNAPSHOT_TTL_FRESH_SECONDS` is greater than or equal to `SNAPSHOT_TTL_STALE_SERVE_SECONDS`, THEN THE backend SHALL fail startup with an error message that names both variables and their values and SHALL NOT start the HTTP server.
4. IF `SNAPSHOT_REFRESH_INTERVAL_SECONDS` is less than `1`, THEN THE backend SHALL fail startup with an error message that names the variable and its value and SHALL NOT start the HTTP server.
5. THE backend SHALL preserve the existing environment variables defined by the `ring-adapter-backend` spec without changing their names, defaults, or semantics.
6. THE `.env.example` file in `partner-auth-backend/` SHALL document every new environment variable introduced by this spec with placeholder values and explanatory comments.

### Requirement 10: Health and Observability

**User Story:** As a backend operator debugging the stack, I want a single administrative endpoint that reports per-Source health, last-success timestamps, active stream counts, and snapshot cache freshness, so that I can tell within seconds whether real data is flowing.

#### Acceptance Criteria

1. THE backend SHALL extend the existing `GET /health/adapter` endpoint to include, under a key `sources`, an entry per Source in the Routing_Profile with fields `mode`, `health_state`, `last_success_at` per operation, and `consecutive_failures` per operation.
2. THE `GET /health/adapter` endpoint SHALL include under a key `snapshot_cache` the current entry count, the total cached byte size, the oldest entry age in seconds, and the newest entry age in seconds.
3. THE `GET /health/adapter` endpoint SHALL include under a key `active_streams` the current count of Session_Map entries grouped by Source mode.
4. THE `GET /health/adapter` endpoint SHALL require the existing API_Key_Check.
5. WHEN a Source is invoked for an operation, THE backend SHALL emit a structured log record with fields `request_id`, `operation`, `source_mode`, `outcome` (one of `ok`, `fallback_eligible`, `non_fallback`), and `failure_class` when the outcome is not `ok`.
6. WHEN the Source_Router makes a routing decision that differs from attempting the primary Source (fallback triggered, quarantine skip, or cache stale-serve), THE backend SHALL emit a structured log record with fields `request_id`, `operation`, `decision` (one of `fallback`, `quarantine_skip`, `stale_cache_serve`), `from_source`, `to_source` or `served_from`, and `failure_class` when applicable.
7. WHEN the Snapshot_Refresh_Job completes a cycle, THE backend SHALL emit a structured log record with fields `event=snapshot_refresh_cycle`, `devices_attempted`, `devices_refreshed`, `devices_failed`, `elapsed_ms`, and `source_mode`.

### Requirement 11: Security

**User Story:** As a backend operator handling real-account credentials, I want the live-media path to preserve all existing secret-handling guarantees and to add none of its own leak vectors, so that routing changes never become a new disclosure path.

#### Acceptance Criteria

1. THE Source_Router SHALL NOT include any access token, refresh token, partner client secret, unofficial Ring session cookie, or value of the `Authorization` header in any response body, response header, log record, or diagnostic output.
2. THE `X-Ring-Source` and `X-Ring-Snapshot-Age` response headers defined by this spec SHALL contain only the Adapter_Mode string and a non-negative integer respectively, and SHALL NOT contain any secret or device identifier.
3. THE Snapshot_Cache SHALL store only snapshot image bytes, content type, timestamp, and producing Adapter_Mode, and SHALL NOT store access tokens, refresh tokens, or any credential material.
4. WHEN the Source_Router attaches an Active_Source identifier to a response or log record, THE Source_Router SHALL use the Adapter_Mode string (one of `partner`, `unofficial`, `mock`) and SHALL NOT use a value derived from a secret.
5. THE backend SHALL continue to enforce the existing API_Key_Check on `GET /api/token` and `GET /health/adapter` regardless of the configured Routing_Profile.
6. THE Partner_Ring_Adapter SHALL obtain the partner access token only from the existing partner OAuth flow already implemented in `partner-auth-backend`, and SHALL NOT read the partner client secret from any location other than the existing secret-handling code path.

### Requirement 12: Backward Compatibility with the Mock Route Surface

**User Story:** As a tvOS app developer, I want the backend to serve real live media without requiring any change to the client's URLs, request bodies, or response bodies, so that the client remains unaware of which upstream is in use.

#### Acceptance Criteria

1. THE Mock_Route_Surface paths `GET /mock/devices`, `GET /mock/history/devices/{device_id}/events`, `POST /mock/devices/{device_id}/media/image/download`, `POST /mock/devices/{device_id}/media/video/download`, `POST /mock/devices/{device_id}/media/streaming/whep/sessions`, and `DELETE /mock/session/{session_id}` SHALL remain the only client-facing routes for these operations regardless of the configured Routing_Profile.
2. THE request content types, request body shapes, and path parameter names accepted by the Mock_Route_Surface SHALL NOT change as a result of this spec.
3. THE response content types and response body shapes produced by the Mock_Route_Surface SHALL match the shapes produced by the Mock_Ring_Adapter in the `ring-adapter-backend` spec, regardless of which Source produced the response.
4. WHEN the Partner_Ring_Adapter produces a WHEP response, THE backend SHALL propagate the response body as `application/sdp`, the `Location` header with the backend-mapped session resource URL (`/mock/session/{session_id}`), and HTTP status 201, matching the existing Mock_Ring_Adapter output.
5. WHEN any Source produces a snapshot response, THE backend SHALL set the HTTP response `Content-Type` to the content type reported by the Source and SHALL return the snapshot bytes unmodified as the response body.
6. THE addition of the `X-Ring-Source` and `X-Ring-Snapshot-Age` response headers SHALL be purely additive and SHALL NOT require the tvOS client to read either header to operate correctly.

### Requirement 13: Testable Correctness Properties

**User Story:** As a backend developer, I want the routing policy, session cleanup, snapshot freshness, and source isolation properties to be expressible as deterministic, checkable properties, so that the behavior is test-driven and regressions are caught quickly.

#### Acceptance Criteria

1. FOR ALL Routing_Profile values containing at least one Real_Source that returns `ok` for a given operation, THE Source_Router's response SHALL carry an `X-Ring-Source` header equal to a Real_Source mode (fallback determinism).
2. FOR ALL successful `create_stream_session` responses followed by a matching `delete_stream_session` call, THE Session_Map SHALL contain no entry for the `session_id` after the `delete_stream_session` call returns (session cleanup).
3. FOR ALL `download_snapshot` responses that do not include the `X-Ring-Snapshot-Age` header, THE Snapshot_Cache entry for the corresponding `device_id` SHALL have age less than `SNAPSHOT_TTL_FRESH_SECONDS` at the time the response is produced (snapshot freshness invariant).
4. FOR ALL pairs of concurrent Sources producing responses for the same request, THE backend SHALL commit at most one response to the client and SHALL ensure that session handles, snapshot bytes, and content types written to shared state come from exactly one Source (no cross-source leakage).
5. FOR ALL invocations of the Snapshot_Refresh_Job, THE Snapshot_Cache byte total after the cycle SHALL be less than or equal to `SNAPSHOT_CACHE_MAX_BYTES` (cache bound invariant).
6. FOR ALL Source_Router responses produced via the fallback path, THE log stream SHALL contain a `decision=fallback` record whose `request_id` equals the response's `request_id` (fallback observability invariant).
7. THE Session_Map SHALL be stored in process memory only. WHEN the backend starts, any previously active upstream sessions (Partner WHEP or unofficial SIP) SHALL be left to expire via their upstream TTLs; the backend SHALL NOT attempt to reconcile or clean up sessions from a prior process (session volatility invariant).
