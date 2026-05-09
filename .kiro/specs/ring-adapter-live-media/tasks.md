# Implementation Plan: Ring Adapter Live Media

## Overview

This plan implements the Source Router, Partner Ring Adapter, Snapshot Cache, and supporting infrastructure that delivers real live video and snapshots to the tvOS client. Tasks are ordered so each builds on the previous — foundational types first, then components, then wiring, then tests.

## Tasks

- [x] 1. Foundation types and error extensions
  - [x] 1.1 Create `FailureClass` enum and fallback-eligible sets
    - Create `app/adapters/failure_class.py` with the `FailureClass` StrEnum
    - Define `FALLBACK_ELIGIBLE` and `SNAPSHOT_FALLBACK_ELIGIBLE` frozensets
    - Export from `app/adapters/__init__.py`
    - _Requirements: 1.5, 1.6, 1.7_

  - [x] 1.2 Extend `RingAdapterError` hierarchy with `failure_class` attribute
    - Add `failure_class: FailureClass` class attribute to each existing error subclass in `app/adapters/errors.py`
    - Add new error subclasses: `UpstreamUnavailableError`, `UpstreamTimeoutError`, `SnapshotUnavailableError`, `StreamCapacityExceededError`, `SubscriptionRequiredError` (if not already present)
    - Ensure each maps to the correct `FailureClass`, `http_status`, and `ErrorCode`
    - _Requirements: 1.5, 1.6, 2.5–2.9, 4.2–4.4, 5.2–5.6_

  - [x] 1.3 Create `SourceResult` wrapper type
    - Create `app/routing/__init__.py` and `app/routing/source_result.py`
    - Implement frozen dataclass with `payload`, `source_mode`, `cache_age_seconds`, and optional `error` field
    - _Requirements: 1.8, 6.9, 6.10_

  - [x] 1.4 Extend `StreamSessionMap` with tagged union session types
    - Add `PartnerStreamSession`, `UnofficialStreamSession`, `MockStreamSession` dataclasses to `app/adapters/types.py`
    - Update `StreamSessionMap` in `app/adapters/session_map.py` to store `BaseStreamSession` instances with `source_mode` field
    - Ensure `bind`, `lookup`, `remove` work with the new types
    - _Requirements: 2.3, 3.2, 13.2_

- [x] 2. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 3. Configuration parsing and validation
  - [x] 3.1 Extend `Settings` with new environment variables
    - Add routing, snapshot cache, and quarantine fields to `app/config.py`
    - Implement `_parse_routing_profile()` with trimming, lowercasing, deduplication check, and token validation
    - Implement `_validate_snapshot_config()` for TTL constraint and refresh interval validation
    - Fail startup with descriptive error messages on invalid config
    - _Requirements: 1.1, 1.2, 1.3, 1.10, 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x] 3.2 Write property test for routing profile parser (Property 1)
    - **Property 1: Routing Profile Parser Correctness**
    - Test that for any input string, the parser either produces a valid normalized list or raises ConfigurationError
    - Use `hypothesis.strategies.text()` and `st.lists(st.sampled_from(modes))`
    - **Validates: Requirements 1.1, 1.3**

  - [x] 3.3 Write unit tests for configuration validation edge cases
    - Test: both vars unset → startup failure
    - Test: fresh ≥ stale → startup failure
    - Test: refresh interval < 1 → startup failure
    - Test: duplicate tokens → startup failure
    - Test: invalid token → startup failure
    - Test: valid single-entry fallback from RING_ADAPTER
    - _Requirements: 1.3, 1.10, 9.3, 9.4_

- [x] 4. HealthManager component
  - [x] 4.1 Implement `HealthManager` class
    - Create `app/routing/health_manager.py`
    - Implement binary `up`/`down` state machine per (source_mode, operation)
    - Implement `is_down()` with lazy quarantine expiry check
    - Implement `record_success()` — resets counter, marks up, records timestamp
    - Implement `record_failure()` — increments counter, quarantines at threshold
    - Implement `snapshot()` for health endpoint reporting
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6_

  - [x] 4.2 Write property test for health state machine (Property 11)
    - **Property 11: Health State Machine Correctness**
    - Test that consecutive_failures equals count since last success, state transitions to down iff threshold reached, single success resets, non-fallback failures don't change state
    - **Validates: Requirements 8.1, 8.2, 8.5, 8.6**

  - [x] 4.3 Write property test for quarantine lifecycle (Property 12)
    - **Property 12: Quarantine Lifecycle**
    - Test that quarantined sources are skipped during window and restored after expiry
    - Use time mocking to simulate quarantine window progression
    - **Validates: Requirements 8.3, 8.4**

- [x] 5. SnapshotCache component
  - [x] 5.1 Implement `SnapshotCache` class
    - Create `app/routing/snapshot_cache.py`
    - Implement LRU byte-bounded in-memory cache with `threading.Lock`
    - Implement `get()` — returns fresh entry or None
    - Implement `get_stale()` — returns stale-but-servable entry or None
    - Implement `put()` — insert/update with LRU eviction when over byte bound
    - Implement reporting properties: `total_bytes`, `entry_count`, `oldest_age`, `newest_age`
    - _Requirements: 6.1, 6.2, 6.8, 6.11, 6.12_

  - [x] 5.2 Write property test for cache bound invariant (Property 10)
    - **Property 10: Cache Bound Invariant**
    - Test that for any sequence of put() operations, total_bytes ≤ max_bytes after each operation
    - Use `hypothesis.strategies` to generate random byte sequences of varying sizes
    - **Validates: Requirements 6.11, 13.5**

  - [x] 5.3 Write unit tests for SnapshotCache TTL semantics
    - Test: fresh entry returned by get(), stale entry not returned by get()
    - Test: stale entry returned by get_stale(), expired entry not returned
    - Test: LRU eviction order is correct
    - Test: put() updates existing entry correctly
    - _Requirements: 6.2, 6.8, 6.11_

- [x] 6. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 7. SourceRouter core routing algorithm
  - [x] 7.1 Implement `SourceRouter` class with `_route_operation()`
    - Create `app/routing/source_router.py`
    - Implement core routing loop: iterate profile in order, skip quarantined, attempt each source
    - Implement fallback-eligible vs non-fallback classification
    - Implement "always show real data" guard (skip mock for live media when real source is up)
    - Implement structured logging for routing decisions
    - _Requirements: 1.4, 1.5, 1.6, 1.7, 1.9, 1.11, 7.1, 7.2, 7.3_

  - [x] 7.2 Implement `download_snapshot()` with cache-first path
    - Check fresh cache first → return without invoking any adapter
    - On cache miss, route through profile → write to cache on success
    - On all-fail, attempt stale-serve → return with `X-Ring-Snapshot-Age`
    - On no stale entry, return error
    - _Requirements: 6.2, 6.3, 6.8, 6.9, 6.10, 7.4_

  - [x] 7.3 Implement `create_stream_session()` and `delete_stream_session()`
    - `create_stream_session`: route through profile (live media path)
    - `delete_stream_session`: lookup session in map, dispatch to owning adapter
    - _Requirements: 2.3, 2.4, 3.2, 3.3_

  - [x] 7.4 Implement remaining operations (`list_devices`, `list_events`, `download_video`)
    - Route through profile with standard fallback logic (not live media path)
    - _Requirements: 1.4, 1.9_

  - [x] 7.5 Write property test for routing determinism (Property 2)
    - **Property 2: Routing Determinism**
    - Test that sources are attempted in strict profile order, skipping only quarantined ones
    - Use FakeAdapter instances with configurable success/failure responses
    - **Validates: Requirements 1.4, 1.5, 1.11**

  - [x] 7.6 Write property test for non-fallback stops routing (Property 3)
    - **Property 3: Non-Fallback Stops Routing**
    - Test that non-fallback failures are returned immediately without trying next source
    - **Validates: Requirements 1.6**

  - [x] 7.7 Write property test for real data guarantee (Property 4)
    - **Property 4: Real Data Guarantee**
    - Test that mock is never used for live media when a real source is up
    - **Validates: Requirements 1.7, 7.1, 7.2, 7.4**

  - [x] 7.8 Write property test for X-Ring-Source header correctness (Property 5)
    - **Property 5: X-Ring-Source Header Correctness**
    - Test that X-Ring-Source always equals the mode of the adapter that produced the payload
    - **Validates: Requirements 1.8, 6.10, 13.1**

  - [x] 7.9 Write property test for cache-first snapshot path (Property 8)
    - **Property 8: Cache-First Snapshot Path**
    - Test that fresh cache entries are returned without invoking any adapter
    - **Validates: Requirements 6.2, 13.3**

  - [x] 7.10 Write property test for stale-serve with age header (Property 9)
    - **Property 9: Stale-Serve with Age Header**
    - Test that stale entries are served with correct X-Ring-Snapshot-Age when all sources fail
    - **Validates: Requirements 6.8, 6.9, 6.10**

- [x] 8. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 9. Partner Ring Adapter
  - [x] 9.1 Implement `PartnerRingAdapter` class
    - Create `app/adapters/partner.py`
    - Implement `mode()` → `"partner"`
    - Implement `list_devices()`, `list_events()` with Partner API calls
    - Implement `download_snapshot()` with POST to media/image/download
    - Implement `download_video()` with POST to media/video/download
    - Implement `create_stream_session()` with WHEP POST, session binding, UUID generation
    - Implement `delete_stream_session()` with DELETE to partner session URL, map removal
    - Set timeouts: 10s for create/snapshot/clip, 5s for delete
    - _Requirements: 2.1–2.10, 4.1–4.7_

  - [x] 9.2 Implement Partner failure-class mapping helpers
    - `_raise_for_whep_status()`: map 401→auth, 402→subscription, 403/404→not_found, 429→rate_limited, 5xx→upstream_unavailable
    - `_raise_for_snapshot_status()`: map 204/404→snapshot_unavailable, 401→auth, 5xx→upstream_unavailable
    - `_raise_for_status()`: general mapping for list_devices, list_events, download_video
    - Handle timeout exceptions → `UpstreamTimeoutError`
    - Handle network errors → `UpstreamUnavailableError`
    - _Requirements: 2.5–2.9, 4.2–4.4, 4.6_

  - [x] 9.3 Write unit tests for Partner adapter failure classification
    - Test each HTTP status code mapping (401, 402, 403, 404, 429, 5xx, timeout)
    - Test successful WHEP session creation and SDP answer passthrough
    - Test session deletion (success and failure both remove from map)
    - _Requirements: 2.1–2.10, 4.1–4.7_

- [x] 10. Unofficial Ring Adapter extensions
  - [x] 10.1 Add `failure_class` attribute to existing Unofficial adapter errors
    - Ensure all `RingAdapterError` raises in `unofficial.py` use the correct subclass with `failure_class`
    - Add snapshot timeout tightening to 10 seconds
    - Ensure `snapshot_unavailable` classification for 404/204 on snapshot fetch
    - Ensure `capacity_exceeded` classification when session limit reached
    - _Requirements: 3.5, 3.6, 3.7, 5.1–5.6_

  - [x] 10.2 Align `UnofficialRingAdapter` session map entries with tagged union
    - Update `create_stream_session` to bind `UnofficialStreamSession` instances
    - Update `delete_stream_session` to work with new session type
    - _Requirements: 3.2, 3.3_

  - [x] 10.3 Write property test for capacity enforcement (Property 13)
    - **Property 13: Capacity Enforcement**
    - Test that when session count ≥ max, create_stream_session raises capacity_exceeded without contacting SIP bridge
    - **Validates: Requirements 3.5**

- [x] 11. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 12. SnapshotRefreshJob
  - [x] 12.1 Implement `SnapshotRefreshJob` class
    - Create `app/routing/snapshot_refresh_job.py`
    - Implement periodic loop with configurable interval
    - Implement skip-if-running via `asyncio.Lock.locked()` check
    - Implement `_execute_cycle()`: get device list via SourceRouter, refresh each device's snapshot
    - Handle `snapshot_unavailable` and `rate_limited` by skipping device for current cycle
    - Emit structured log on cycle completion with devices_attempted, devices_refreshed, devices_failed, elapsed_ms
    - _Requirements: 6.4, 6.5, 6.6, 6.7, 10.7_

  - [x] 12.2 Write property test for skip-if-running (Property 14)
    - **Property 14: Skip-If-Running Refresh**
    - Test that at most one refresh cycle executes at any time
    - **Validates: Requirements 6.4**

  - [x] 12.3 Write property test for refresh participates in quarantine (Property 15)
    - **Property 15: Refresh Participates in Quarantine**
    - Test that refresh job failures increment the same quarantine counter as client requests
    - **Validates: Requirements 6.6**

- [x] 13. Route handler refactoring and header injection
  - [x] 13.1 Refactor `/mock/*` route handlers to use `SourceRouter`
    - Replace direct `RingAdapter` dependency injection with `SourceRouter` in all route handlers
    - Update `GET /mock/devices`, `GET /mock/history/...`, `POST .../image/download`, `POST .../video/download`, `POST .../whep/sessions`, `DELETE /mock/session/{id}`
    - Attach `X-Ring-Source` header from `SourceResult.source_mode` on every response
    - Attach `X-Ring-Snapshot-Age` header when `SourceResult.cache_age_seconds` is set
    - Preserve existing request/response shapes unchanged
    - _Requirements: 1.8, 6.9, 6.10, 12.1–12.6_

  - [x] 13.2 Write property test for fallback observability (Property 16)
    - **Property 16: Fallback Observability**
    - Test that fallback routing decisions produce structured log records with decision=fallback and matching request_id
    - **Validates: Requirements 13.6**

  - [x] 13.3 Write property tests for session lifecycle (Properties 6 and 7)
    - **Property 6: Session Binding Invariant**
    - **Property 7: Session Cleanup Invariant**
    - Test that create binds exactly one entry, delete removes it regardless of upstream success/failure
    - **Validates: Requirements 2.3, 2.4, 3.2, 3.3, 13.2**

- [x] 14. Health endpoint extension
  - [x] 14.1 Extend `GET /health/adapter` with source health, cache, and stream data
    - Add `sources` key with per-source, per-operation health state, consecutive_failures, last_success_at
    - Add `snapshot_cache` key with entry_count, total_bytes, oldest_entry_age_seconds, newest_entry_age_seconds
    - Add `active_streams` key with session count grouped by source mode
    - Add `routing_profile` key showing configured profile
    - Preserve existing API_Key_Check enforcement
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 11.5_

  - [x] 14.2 Write unit tests for health endpoint response shape
    - Verify all required fields are present
    - Verify API key is required
    - Verify response matches documented schema
    - _Requirements: 10.1–10.4_

- [x] 15. Dependency injection and application wiring
  - [x] 15.1 Update `app/dependencies.py` and `app/main.py` for SourceRouter assembly
    - Instantiate `HealthManager`, `SnapshotCache`, `SourceRouter` at startup based on parsed config
    - Instantiate `PartnerRingAdapter` (when `partner` in profile) with existing `TokenService`
    - Instantiate `SnapshotRefreshJob` and start it on app startup, stop on shutdown
    - Update adapter factory to support `partner` mode
    - Wire `SourceRouter` as the dependency for route handlers
    - _Requirements: 1.1, 1.2, 9.1, 9.5_

  - [x] 15.2 Add structured logging for routing decisions and source invocations
    - Log `request_id`, `operation`, `source_mode`, `outcome`, `failure_class` on each source invocation
    - Log `decision=fallback`/`quarantine_skip`/`stale_cache_serve` with `from_source`, `to_source`, `request_id`
    - Log `event=live_media_fallback_to_mock` at WARNING level when mock serves live media with real sources configured
    - _Requirements: 7.3, 10.5, 10.6_

- [x] 16. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 17. Configuration files and documentation
  - [x] 17.1 Update `docker-compose.yml` with new environment variables
    - Add `RING_ADAPTER_ROUTING`, `SNAPSHOT_TTL_FRESH_SECONDS`, `SNAPSHOT_TTL_STALE_SERVE_SECONDS`, `SNAPSHOT_REFRESH_INTERVAL_SECONDS`, `SNAPSHOT_CACHE_MAX_BYTES`, `SOURCE_QUARANTINE_THRESHOLD`, `SOURCE_QUARANTINE_SECONDS` to backend service
    - Preserve all existing environment variables unchanged
    - _Requirements: 9.1, 9.5_

  - [x] 17.2 Update `.env.example` with new variables and comments
    - Document each new variable with placeholder values and explanatory comments
    - Preserve existing variables
    - _Requirements: 9.6_

- [x] 18. Integration tests
  - [x] 18.1 Write integration test for end-to-end routing with mocked HTTP clients
    - Test full FastAPI app with `RING_ADAPTER_ROUTING=unofficial,mock`
    - Verify routing fallback behavior end-to-end
    - Verify `X-Ring-Source` header on responses
    - _Requirements: 1.4, 1.5, 1.8, 12.1–12.6_

  - [x] 18.2 Write integration test for snapshot refresh job populating cache
    - Start app, trigger refresh cycle, verify cache is populated
    - Verify subsequent snapshot requests are served from cache
    - _Requirements: 6.2, 6.4, 6.5_

  - [x] 18.3 Write integration test for Partner WHEP session lifecycle
    - Mock Partner API, verify SDP offer→answer round-trip
    - Verify Location header mapping to `/mock/session/{id}`
    - Verify DELETE removes session from map
    - _Requirements: 2.1–2.4, 12.4_

  - [x] 18.4 Write integration test for backward compatibility
    - Verify all 6 `/mock/*` endpoints return expected shapes regardless of routing profile
    - Verify request content types and path parameters unchanged
    - _Requirements: 12.1–12.6_

- [x] 19. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- The design uses Python with `httpx`, `asyncio`, FastAPI — all code should follow existing project conventions
- The `app/routing/` package is new; all other changes extend existing files

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "1.3"] },
    { "id": 2, "tasks": ["1.4", "3.1"] },
    { "id": 3, "tasks": ["3.2", "3.3", "4.1", "5.1"] },
    { "id": 4, "tasks": ["4.2", "4.3", "5.2", "5.3"] },
    { "id": 5, "tasks": ["7.1"] },
    { "id": 6, "tasks": ["7.2", "7.3", "7.4"] },
    { "id": 7, "tasks": ["7.5", "7.6", "7.7", "7.8", "7.9", "7.10", "9.1"] },
    { "id": 8, "tasks": ["9.2", "10.1"] },
    { "id": 9, "tasks": ["9.3", "10.2", "10.3"] },
    { "id": 10, "tasks": ["12.1"] },
    { "id": 11, "tasks": ["12.2", "12.3", "13.1"] },
    { "id": 12, "tasks": ["13.2", "13.3", "14.1"] },
    { "id": 13, "tasks": ["14.2", "15.1"] },
    { "id": 14, "tasks": ["15.2", "17.1", "17.2"] },
    { "id": 15, "tasks": ["18.1", "18.2", "18.3", "18.4"] }
  ]
}
```
