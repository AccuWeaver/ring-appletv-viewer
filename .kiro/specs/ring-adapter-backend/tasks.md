# Implementation Plan: Ring Adapter Backend

## Overview

Transform the existing `partner-auth-backend` into a pluggable adapter-based service behind the stable `/mock/*` HTTP surface. Introduce a `RingAdapter` ABC with two concrete implementations (`MockRingAdapter`, `UnofficialRingAdapter`), a Node.js `ring-sip-bridge` sidecar that republishes Ring's SIP streams as RTSP to `mediamtx`, and the supporting machinery (error hierarchy, rate limit governor, refresh token store, log redaction, health endpoints). Selection is driven by a single `RING_ADAPTER` environment variable. Existing partner-auth routes (`/ring/*`, `/api/token`) remain untouched and are validated by a regression test. All Python tests run via `uv run pytest`; lint via `uv run ruff check .`; Node sidecar tests via `npm test`.

## Tasks

- [x] 1. Adapter package scaffolding, error hierarchy, and settings
  - [x] 1.1 Create `app/adapters/` package with `__init__.py` and the `RingAdapter` ABC in `app/adapters/base.py`
    - Declare six abstract async methods (`list_devices`, `list_events`, `download_snapshot`, `download_video`, `create_stream_session`, `delete_stream_session`) plus synchronous `mode()`
    - Define `SnapshotPayload` and `StreamSessionResult` as `typing.NamedTuple`s
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 12.4, 13.1_

  - [x] 1.2 Create the `RingAdapterError` hierarchy in `app/adapters/errors.py`
    - Base class with `code: str` and `http_status: int` class attributes
    - Subclasses: `AdapterConfigurationError`, `AuthenticationRequiredError`, `UpstreamUnavailableError`, `UpstreamTimeoutError`, `RateLimitedError`, `DeviceNotFoundError`, `SubscriptionRequiredError`, `SnapshotUnavailableError`, `StreamCapacityExceededError`, `StreamSessionNotFoundError`
    - _Requirements: 1.8, 11.2, 11.3_

  - [x] 1.3 Create the `ErrorCode` enum in `app/adapters/error_codes.py`
    - Single source of truth for error code strings, referenced by the error classes
    - _Requirements: 1.8, 11.2, 11.3_

  - [x] 1.4 Create internal dataclasses in `app/adapters/types.py`
    - `AccessTokenCacheEntry` (frozen): `token`, `expires_at`
    - `StreamSession`: `session_id`, `bridge_session_id`, `device_id`, `mediamtx_path`, `created_at`, `state`, `has_audio`
    - _Requirements: 6.4_

  - [x] 1.5 Create Pydantic adapter-facing models in `app/adapters/models.py`
    - `DeviceAttributes`, `DeviceResource`, `EventResource` with literal-constrained `power_source`, `status`, event `type`
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [x] 1.6 Create defensive Ring consumer API schemas in `app/adapters/ring_schemas.py`
    - `RingDevice`, `RingDeviceHealth`, `RingEvent`, `RingOAuthTokenResponse` with `extra = "ignore"`
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 3.3_

  - [x] 1.7 Extend `app/config.py` with new settings
    - Add `ring_adapter` (default `"mock"`), `ring_refresh_token` (optional), `ring_max_concurrent_streams` (default 2), `ring_api_rate_limit_per_minute` (default 60), `mediamtx_rtsp_url`, `mediamtx_whep_base`, `ring_sip_bridge_url`
    - Validate `ring_adapter in {"mock", "unofficial"}`; raise `ConfigurationError` otherwise
    - Preserve existing partner-auth env var validation
    - _Requirements: 7.1, 7.2, 7.6, 7.7, 7.8_

- [x] 2. Mock adapter refactor and regression tests
  - [x] 2.1 Implement `MockRingAdapter` in `app/adapters/mock.py`
    - Port `MOCK_DEVICES`, `_generate_mock_events`, `_BLUE_PIXEL_PNG`, the mediamtx WHEP proxy, and the stub SDP answer verbatim from `app/routes/mock_ring_api.py` into methods
    - `mode()` returns `"mock"`; no outbound calls to `*.ring.com`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8_

  - [x] 2.2 Refactor `app/routes/mock_ring_api.py` into thin delegators
    - Each handler becomes a one-liner that calls `adapter.<method>(…)` via `Depends(get_ring_adapter)`
    - Delete in-route response construction; keep only URL shapes and argument extraction
    - _Requirements: 7.4, 12.5_

  - [x] 2.3 Create `app/dependencies.py` with the `get_ring_adapter` placeholder
    - Raises `RuntimeError` by default; overridden at startup by `main.py`
    - _Requirements: 7.3, 13.1_

  - [x] 2.4 Write property test for mock adapter equivalence in `tests/adapters/test_mock_adapter.py`
    - **Property 1: Mock adapter behavior is unchanged from current routes**
    - For any valid request input, `MockRingAdapter` method output SHALL equal the pre-refactor route output byte-for-byte (modulo the UUID in the `Location` header, matched by regex `^/mock/session/[0-9a-f-]{36}$`)
    - **Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 13.4**

  - [x] 2.5 Write integration regression test in `tests/integration/test_mock_mode_e2e.py`
    - Start the FastAPI app with `RING_ADAPTER=mock`; assert all six `/mock/*` endpoints respond with the captured pre-refactor payloads
    - _Requirements: 2.8, 13.4_

  - [x] 2.6 Write integration regression test for partner-auth route preservation in `tests/integration/test_partner_auth_regression.py`
    - Confirm `/ring/token-exchange`, `/ring/account-link`, `/ring/webhook`, `/ring/app-homepage`, `/api/token`, `/health` respond as they do today under both `RING_ADAPTER=mock` and `RING_ADAPTER=unofficial`
    - _Requirements: 12.1, 12.2, 12.3_

- [x] 3. Checkpoint — Mock adapter regression
  - Ensure all tests pass with `uv run pytest` from `partner-auth-backend/`. Verify the mock surface is byte-for-byte identical to the current behavior and partner-auth routes are unaffected. Ask the user if questions arise.

- [x] 4. Refresh token store
  - [x] 4.1 Implement `RefreshTokenStore` in `app/data/refresh_token_store.py`
    - `initialize()` runs `CREATE TABLE IF NOT EXISTS ring_refresh_token (id INTEGER PRIMARY KEY CHECK (id = 1), refresh_token TEXT NOT NULL, is_valid INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)`
    - `load()`, `save()`, `rotate()` (single-transaction `UPDATE`), `mark_invalid()`, `is_valid()`
    - Encrypt/decrypt via the existing `FernetEncryptor`
    - _Requirements: 3.1, 3.2, 3.5, 9.1, 9.7_

  - [x] 4.2 Wire `RefreshTokenStore.initialize()` into the existing `TokenStore.initialize()` or into the startup hook
    - Shares `/data/tokens.db`; no new database process
    - _Requirements: 9.1, 10.1_

  - [x] 4.3 Write property test for refresh token round-trip and rotation in `tests/data/test_refresh_token_store.py`
    - **Property 3: Refresh token store round-trip and rotation**
    - After any `save(t1); rotate(t2); …; rotate(tn)` sequence, `load()` returns `tn`; raw ciphertext never equals any plaintext `ti`; when both env bootstrap and stored values exist, the stored value wins
    - **Validates: Requirements 3.1, 3.2, 3.5, 9.1, 9.7, 13.6**

  - [x] 4.4 Write example unit test for `mark_invalid()` behavior
    - `load()` returns `None` after `mark_invalid()`; stored row still exists but `is_valid = 0`
    - _Requirements: 3.7_

- [x] 5. Rate limit governor and mappers
  - [x] 5.1 Implement `RateLimitGovernor` in `app/adapters/rate_limit.py`
    - Monotonic-time deque, `asyncio.Lock`, `acquire()` blocks up to `queue_wait_seconds` then raises `RateLimitedError`
    - `current_rate()` returns the count of events in the last 60 s
    - _Requirements: 8.1, 8.2_

  - [x] 5.2 Implement device and event mappers in `app/adapters/mappers.py`
    - `map_device(RingDevice) -> DeviceResource` (derive `power_source` from `battery_life`, default `status` to `"online"`)
    - `map_event(RingEvent, device_id) -> EventResource`
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [x] 5.3 Write property test for rate limit governor in `tests/adapters/test_rate_limit_governor.py`
    - **Property 5: Rate limit governor enforces rolling window**
    - For any `max_per_minute in [1, 300]` and any `acquire()` schedule, the governor allows at most `max_per_minute` successful acquisitions in any rolling 60 s window; contended requests either drain within 5 s or raise `RateLimitedError`
    - **Validates: Requirements 8.1, 8.2**

  - [x] 5.4 Write property test for device and event mapping in `tests/adapters/test_mappers.py`
    - **Property 9: Device and event mapping conform to the contract**
    - Random `RingDevice` and `RingEvent` inputs produce `DeviceResource` / `EventResource` that pass Pydantic validation; `list_events(device_id, limit)` returns at most `limit` items for `limit in [0, 100]`
    - **Validates: Requirements 4.1, 4.2, 4.3, 4.4**

- [x] 6. Ring consumer client
  - [x] 6.1 Implement `RingConsumerClient` in `app/adapters/ring_consumer_client.py`
    - Constructor takes `httpx.AsyncClient`, `RateLimitGovernor`, `RefreshTokenStore`
    - `ensure_access_token()` — `asyncio.Lock`-guarded cached token; refresh when `<= 60s` to expiry
    - `_refresh()` — POST to `https://oauth.ring.com/oauth/token`; on new `refresh_token`, call `store.rotate(new)`; on 401 call `store.mark_invalid()` and raise `AuthenticationRequiredError`
    - `get_devices()`, `get_history(device_id, limit)`, `get_snapshot(device_id)`, `get_clip_url(event_id)` against `https://api.ring.com`
    - Per-request timeout 10 s; `User-Agent: ring-adapter-backend/<version>`
    - Retry policy: honor `Retry-After` on 429; exponential 1→30 s otherwise; up to 2 retries on 5xx; otherwise raise `UpstreamUnavailableError` / `UpstreamTimeoutError`
    - Response caching: 30 s for `get_devices`, 10 s for `get_history`; no caching for snapshots or clip URLs
    - _Requirements: 3.3, 3.4, 3.5, 3.7, 3.8, 4.6, 5.5, 8.3, 8.4, 8.5, 8.6_

  - [x] 6.2 Write property test for access token refresh threshold in `tests/adapters/test_ring_consumer_client.py`
    - **Property 4: Access token refresh threshold**
    - For any random `expires_in` in `[60, 86400]` and simulated "now", `ensure_access_token()` calls the OAuth endpoint again iff `(expires_at - now) <= 60s`
    - **Validates: Requirements 3.3, 3.4**

  - [x] 6.3 Write example unit tests for `RingConsumerClient` retry and header behavior
    - 429 with `Retry-After` → honored exactly once
    - 429 without `Retry-After` → exponential 1→2→4→8→16→30 s
    - 5xx retried up to 2 times then raises `UpstreamUnavailableError`
    - Per-request timeout set to 10 s
    - `User-Agent` header includes backend name and version
    - Refresh response containing new `refresh_token` triggers `store.rotate()`
    - Refresh 401 → `AuthenticationRequiredError` + `store.mark_invalid()`
    - _Requirements: 3.5, 3.7, 8.3, 8.4, 8.5, 8.6_

- [x] 7. Node.js SIP bridge sidecar
  - [x] 7.1 Create `ring-sip-bridge/` directory with package metadata
    - `package.json` pinning Node 20, `ring-client-api` (pinned version), `express` or equivalent HTTP framework, test runner (`vitest` — document choice in a top-level `README.md`)
    - `.gitignore` and `.dockerignore` for `node_modules/`
    - _Requirements: 6.1, 6.2_

  - [x] 7.2 Create `ring-sip-bridge/Dockerfile` for a Node 20-slim image
    - Install deps, copy sources, expose port 3000, non-root user where possible
    - _Requirements: 10.1_

  - [x] 7.3 Implement `ring-sip-bridge/index.js` HTTP control plane
    - `POST /sessions` — body `{device_id, refresh_token}`; negotiate SIP via `ring-client-api`; spawn RTP→RTSP republisher to `${MEDIAMTX_RTSP_URL}/${device_id}`; return `{bridge_session_id, rtsp_path}`
    - `DELETE /sessions/{bridge_session_id}` — terminate SIP, stop RTSP publish, idempotent
    - `GET /sessions` — list active sessions
    - `GET /health` — `{status, active_sessions}`
    - Error cases: 409 `device_busy`, 502 `sip_failed`
    - No secrets persisted to disk; refresh token only held in-memory for the session duration
    - _Requirements: 6.1, 6.2, 6.5, 6.6, 6.8_

  - [x] 7.4 Implement SIP-termination watchdog
    - On Ring-initiated SIP termination (camera offline, network break), stop RTSP publish within 5 s and mark the session terminated
    - _Requirements: 6.6_

  - [x] 7.5 Create test harness in `ring-sip-bridge/test/` mocking Ring's SIP signaling
    - Fake `ring-client-api` shim returning fixed RTP endpoints
    - Exercise happy-path `POST /sessions` → `DELETE /sessions/{id}` with `npm test`
    - Exercise error paths: Ring SIP failure → 502, device busy → 409
    - Exercise audio-absent case: republish with video only, `has_audio: false`
    - _Requirements: 6.1, 6.5, 6.6, 6.8_

- [x] 8. Video bridge integration
  - [x] 8.1 Implement `SipBridgeClient` in `app/adapters/sip_bridge_client.py`
    - `start(device_id)` — POST to sidecar; raise `StreamCapacityExceededError` on 409, `UpstreamUnavailableError` on 5xx, `UpstreamTimeoutError` when `POST /sessions` exceeds 15 s
    - `stop(bridge_session_id)` — idempotent DELETE
    - `healthy()` — GET `/health`
    - Refresh token is injected per-call via the `refresh_token_provider` callable
    - _Requirements: 6.1, 6.5, 6.7, 13.3_

  - [x] 8.2 Implement `StreamSessionMap` in `app/adapters/session_map.py`
    - `asyncio.Lock`-protected `dict[session_id, StreamSession]`
    - `bind`, `lookup`, `remove`, `count`, `check_capacity(max_concurrent)`
    - _Requirements: 6.4, 6.5, 6.7_

  - [x] 8.3 Implement `UnofficialRingAdapter` in `app/adapters/unofficial.py`
    - Compose `RingConsumerClient`, `SipBridgeClient`, `StreamSessionMap`, `max_concurrent`, `mediamtx_whep_base`
    - Implement all six `RingAdapter` methods; map upstream errors to `RingAdapterError` subclasses
    - `create_stream_session`: capacity check → sidecar start → session ID binding → mediamtx WHEP proxy → return `StreamSessionResult`
    - `delete_stream_session`: lookup → sidecar stop → session removal; raise `StreamSessionNotFoundError` on unknown id
    - `aclose()` terminates all active sessions
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.1, 5.2, 5.3, 5.4, 5.5, 6.1, 6.3, 6.4, 6.5, 6.7, 6.8_

  - [x] 8.4 Write property test for stream session lifecycle in `tests/adapters/test_unofficial_adapter.py`
    - **Property 10: Stream session lifecycle invariants**
    - For any random sequence of `create_stream_session` and `delete_stream_session` calls against a fake `SipBridgeClient` with `max_concurrent in [1, 10]`: unique session IDs, live count never exceeds the cap, capacity errors raised before sidecar contact, `lookup` semantics after create/delete are consistent
    - **Validates: Requirements 6.4, 6.5, 6.7**

  - [x] 8.5 Write example unit tests for `UnofficialRingAdapter` error translation
    - Ring 404 on device → `DeviceNotFoundError` → 404
    - Ring 404 on snapshot → `SnapshotUnavailableError` → 503
    - Ring 402 / clip subscription path → `SubscriptionRequiredError` → 402
    - Sidecar 15 s timeout → `UpstreamTimeoutError` → 504
    - Snapshot and clip URLs are not cached
    - _Requirements: 4.5, 5.2, 5.4, 5.5_

- [x] 9. Adapter factory and DI wiring
  - [x] 9.1 Implement `create_adapter()` in `app/adapters/factory.py`
    - Mock branch: returns `MockRingAdapter(mediamtx_whep_url=...)`
    - Unofficial branch: `_bootstrap_refresh_token` (prefers stored over env), builds `httpx.AsyncClient`, `RateLimitGovernor`, `RingConsumerClient`, `SipBridgeClient`, returns `UnofficialRingAdapter`
    - Any invalid configuration raises `ConfigurationError`
    - _Requirements: 3.1, 3.2, 3.6, 7.1, 7.2, 7.3, 7.5, 7.6_

  - [x] 9.2 Wire the factory into `app/main.py` lifespan
    - Replace the `@app.on_event("startup")` hook with a lifespan-managed `asynccontextmanager`
    - Initialize `TokenStore`, `RefreshTokenStore`, create the adapter, install `app.dependency_overrides[get_ring_adapter] = lambda: adapter`
    - Log a single startup line `startup adapter_mode=<mode>`
    - On shutdown, call `adapter.aclose()`
    - Fail-fast: missing refresh token in unofficial mode → exit non-zero within 5 s
    - _Requirements: 3.6, 7.3, 7.5, 10.6_

  - [x] 9.3 Write property test for single adapter instance in `tests/test_dependency_injection.py`
    - **Property 7: Single adapter instance across requests**
    - For any sequence of HTTP requests, every `Depends(get_ring_adapter)` returns the same Python object (`is` identity), and `mode()` returns the same value in `{"mock", "unofficial"}`
    - **Validates: Requirements 1.7, 7.3**

  - [x] 9.4 Write property test for thin route delegation in `tests/test_route_delegation.py`
    - **Property 8: /mock/* routes are thin delegators**
    - For random inputs to all six `/mock/*` endpoints, injecting a spy adapter (`tests/fakes/adapter_spy.py`) records exactly one call per request with parameters propagated unchanged; route responses derive solely from the adapter return value
    - **Validates: Requirements 7.4, 12.5, 13.1**

  - [x] 9.5 Write example unit tests for the factory fail-fast paths
    - `RING_ADAPTER=invalid` → `ConfigurationError` at startup
    - `RING_ADAPTER=unofficial` + no env + empty store → `ConfigurationError` at startup
    - `RING_ADAPTER=unofficial` + env only → store is seeded encrypted on first load
    - `RING_ADAPTER=unofficial` + env + stored value → stored value wins (bootstrap is a no-op)
    - _Requirements: 3.1, 3.2, 3.6, 7.2, 7.6, 10.6_

- [x] 10. Exception handler and error mapping
  - [x] 10.1 Register the `RingAdapterError` global handler in `app/main.py`
    - Maps each subclass to `JSONResponse(status_code=exc.http_status, content={"error": exc.code})`
    - Logs `request_id`, adapter `mode()`, operation, `device_id` (if present)
    - No route handler catches `RingAdapterError` directly
    - _Requirements: 1.8, 11.2, 11.3_

  - [x] 10.2 Write property test for adapter error → HTTP mapping in `tests/adapters/test_error_mapping.py`
    - **Property 2: Adapter errors map to stable HTTP responses**
    - For every `RingAdapterError` subclass (parameterized), the response body equals `{"error": exc.code}` exactly and the status equals `exc.http_status`; under any induced upstream failure (random status codes, timeouts, connection errors) no non-`RingAdapterError` escapes an adapter method
    - **Validates: Requirements 1.8, 11.2, 11.3**

- [x] 11. Checkpoint — Adapter, factory, and error mapping
  - Run `uv run pytest` and `uv run ruff check .` from `partner-auth-backend/`. Confirm both adapters work behind the same route surface and error envelopes are consistent. Ask the user if questions arise.

- [x] 12. Log redaction
  - [x] 12.1 Implement `RedactingFilter` in `app/logging_redaction.py`
    - Redact known field names (`refresh_token`, `access_token`, `authorization`, `cookie`, `ring_refresh_token`, `ring_access_token`) from `record.args` dicts
    - Regex-redact `field=value` patterns inside `record.msg`
    - Attach to the root logger during app startup
    - _Requirements: 3.8, 9.2, 9.5_

  - [x] 12.2 Write property test for log redaction in `tests/test_log_redaction.py`
    - **Property 6: No plaintext secrets in log output**
    - For any random secret value passed through any adapter operation or logged directly, captured log output contains no plaintext leakage; values referenced by redacted field names produce `[REDACTED]` in emitted records
    - **Validates: Requirements 3.8, 9.2, 9.5**

- [x] 13. Health endpoints
  - [x] 13.1 Update `GET /health` in `app/main.py` to include `adapter_mode`
    - Response: `{"status": "healthy", "adapter_mode": adapter.mode()}`
    - _Requirements: 11.5_

  - [x] 13.2 Add `GET /health/adapter` in `app/main.py`
    - Guarded by the existing `verify_api_key` dependency
    - Returns `{adapter_mode, refresh_token_valid, active_stream_sessions, ring_api_requests_last_minute}`
    - `refresh_token_valid` and `ring_api_requests_last_minute` are `None`/`0` in mock mode
    - _Requirements: 11.6_

  - [x] 13.3 Write example tests for health endpoints in `tests/test_health_endpoints.py`
    - `/health` returns adapter mode in both `mock` and `unofficial` modes
    - `/health/adapter` requires API key (401 without); returns the documented body with correct fields
    - _Requirements: 11.5, 11.6_

- [x] 14. Structured logging for adapter operations and SIP lifecycle
  - [x] 14.1 Add structured log records in adapter method entry/exit
    - Record fields: `request_id`, adapter `mode()`, operation, `device_id`, outcome (`ok`, `upstream_error`, `adapter_error`, `timeout`)
    - _Requirements: 11.1_

  - [x] 14.2 Add structured log records for SIP / RTSP lifecycle events
    - Emit from `UnofficialRingAdapter` and `SipBridgeClient` on `sip_established`, `sip_terminated`, `rtsp_publish_started`, `rtsp_publish_stopped` with `session_id`, `device_id`, adapter `mode()`, and event type
    - _Requirements: 11.4_

- [x] 15. Docker Compose integration
  - [x] 15.1 Update `docker-compose.yml` with new `backend` env vars
    - `RING_ADAPTER`, `RING_REFRESH_TOKEN`, `RING_MAX_CONCURRENT_STREAMS`, `RING_API_RATE_LIMIT_PER_MINUTE`, `MEDIAMTX_RTSP_URL`, `MEDIAMTX_WHEP_BASE`, `RING_SIP_BRIDGE_URL` with mock-safe defaults
    - _Requirements: 10.1, 10.2, 10.3_

  - [x] 15.2 Add the `ring-sip-bridge` service to `docker-compose.yml`
    - Build context `./ring-sip-bridge`, port 3000, depends on `mediamtx`, env `MEDIAMTX_RTSP_URL` and `PORT`
    - _Requirements: 10.1, 10.3_

  - [x] 15.3 Move the `ffmpeg` test-pattern service behind a `mock` Compose profile
    - `profiles: ["mock"]` so `docker compose up` omits it and `docker compose --profile mock up` includes it
    - _Requirements: 10.4_

  - [x] 15.4 Write integration test for startup failure in `tests/integration/test_startup_failures.py`
    - With `RING_ADAPTER=unofficial` and no `RING_REFRESH_TOKEN` and empty store, the backend exits non-zero within 5 s
    - _Requirements: 10.6_

- [x] 16. Documentation
  - [x] 16.1 Update `partner-auth-backend/.env.example`
    - Append the block from the design: `RING_ADAPTER`, `RING_REFRESH_TOKEN` (placeholder only), `RING_MAX_CONCURRENT_STREAMS`, `RING_API_RATE_LIMIT_PER_MINUTE`, `MEDIAMTX_RTSP_URL`, `MEDIAMTX_WHEP_BASE`, `RING_SIP_BRIDGE_URL`
    - Comment pointing to `npx -p ring-client-api ring-auth-cli`; warn against committing the real value
    - _Requirements: 9.3, 10.5_

  - [x] 16.2 Verify `partner-auth-backend/.env` is covered by `.gitignore`
    - Add the entry if missing
    - _Requirements: 9.4_

  - [x] 16.3 Update `partner-auth-backend/README.md`
    - Document `RING_ADAPTER` selection, running under each mode, the 2FA bootstrap procedure for generating a refresh token, manual test procedure against a real Ring account, and the `ring-sip-bridge` sidecar
    - _Requirements: 7.5, 9.3_

  - [x] 16.4 Add a top-level `ring-sip-bridge/README.md`
    - Document the HTTP control plane, Node version, pinned dependencies, `npm test` command, and test framework choice
    - _Requirements: 6.1_

- [x] 17. Final integration tests
  - [x] 17.1 Write unofficial-mode end-to-end test in `tests/integration/test_unofficial_mode_e2e.py`
    - Compose the real `UnofficialRingAdapter` + `RingConsumerClient` + `SipBridgeClient` with the fake Ring API fixture (`tests/fakes/ring_api.py`) and fake SIP bridge fixture (`tests/fakes/sip_bridge.py`); assert each of the six `/mock/*` operations returns the contracted response shape
    - _Requirements: 13.2, 13.3, 13.5_

  - [x] 17.2 Write refresh token rotation integration test
    - Seed the store with `t1`; drive a device request; fake OAuth returns `t2`; assert `load()` decrypts to `t2` and the stored ciphertext differs from both plaintexts
    - _Requirements: 3.5, 9.7, 13.6_

- [x] 18. Final checkpoint — Full regression
  - Run `uv run pytest` and `uv run ruff check .` from `partner-auth-backend/`, and `npm test` from `ring-sip-bridge/`. Verify both `docker compose up` (default) and `docker compose --profile mock up` start cleanly. Confirm no plaintext token values appear in captured logs. Ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP. Property tests, unit tests, and integration tests are all optional sub-tasks; core implementation tasks are never marked optional.
- All Python commands use `uv run pytest` and `uv run ruff check .` to match the existing project setup. Node sidecar tests use `npm test` from `ring-sip-bridge/`.
- The ten correctness properties from the design are distributed across tasks 2, 4, 5, 6, 8, 9, 10, and 12 so each property test sits next to the code it validates.
- Partner-auth routes (`/ring/*`, `/api/token`) are preserved unchanged; Task 2.6 provides an explicit regression check.
- The `ring-sip-bridge` sidecar is always built but only exercised when `RING_ADAPTER=unofficial`; its idle cost in mock mode is negligible.
- Checkpoints at tasks 3, 11, and 18 give natural verification points for the user to pause and review.
