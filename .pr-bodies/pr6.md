## Part 6 — ring-adapter-backend: pluggable Ring adapter behind `/mock/*`

Builds the pluggable-adapter architecture described in `.kiro/specs/ring-adapter-backend/`. The tvOS app is unchanged — every existing `/mock/*` URL, request shape, and response shape is preserved. A new `RING_ADAPTER` env var (default `mock`) picks between `MockRingAdapter` (the current hardcoded behaviour) and `UnofficialRingAdapter` (your real Ring account, via the unofficial consumer API).

### Architecture

- **`RingAdapter` ABC** — six async operations (`list_devices`, `list_events`, `download_snapshot`, `download_video`, `create_stream_session`, `delete_stream_session`) plus `mode()`. Single point of extension when Partner API approval lands.
- **`MockRingAdapter`** — byte-for-byte port of the legacy route behaviour. No outbound Ring traffic.
- **`UnofficialRingAdapter`** — calls `api.ring.com` via `RingConsumerClient`; streams camera video through a `ring-sip-bridge` Node sidecar that republishes Ring's SIP/RTP as RTSP into mediamtx.
- **`RingAdapterError` hierarchy + single global exception handler** — every failure maps to `{"error": "<code>"}` with a stable HTTP status; no stack traces or Ring error bodies leak to the client.
- **Fail-fast startup** — invalid `RING_ADAPTER`, missing refresh token in unofficial mode, or broken encryptor exits non-zero within 5 s so `docker compose up` surfaces the misconfiguration.

### Security

- Ring refresh token stored encrypted at rest via the existing `FernetEncryptor`, in a new singleton-row `ring_refresh_token` table (shares `/data/tokens.db`).
- `RefreshTokenStore.rotate()` is a single-transaction UPDATE so a crash cannot leave the store half-updated.
- `RedactingFilter` attached to the root logger scrubs `refresh_token`, `access_token`, `authorization`, `cookie` from every log record — field-name redaction plus regex pattern redaction of `field=value` inside message bodies.
- On OAuth 401, the stored token is marked invalid *before* `AuthenticationRequiredError` is raised.
- Stored token wins over env-var bootstrap so a rotated token is never clobbered by a stale `.env` value.

### Hygiene on outbound traffic

- `RateLimitGovernor`: rolling 60 s window, monotonic-time deque, `asyncio.Lock`. Queues up to 5 s on contention before raising `RateLimitedError`.
- Retry policy: honors `Retry-After` on 429; otherwise capped-exponential 1→30 s with ±20% jitter. Retries 5xx up to twice.
- Per-request timeout 10 s; identifying `User-Agent` header on every outbound call.
- Response cache: 30 s for device lists, 10 s for event history, never for snapshots or clip URLs.

### Node.js `ring-sip-bridge` sidecar

- Small Node 20 service that wraps `ring-client-api` behind a minimal HTTP control plane (`POST /sessions`, `DELETE /sessions/:id`, `GET /sessions`, `GET /health`).
- Refresh token passed per-request from the backend; held only in memory for the session lifetime.
- Stops the RTSP publish within 5 s when Ring ends the SIP session.
- Vitest harness covers happy path, Ring SIP failure (502), device busy (409), and audio-absent (video-only republish with `has_audio: false`).

### Observability

- `GET /health` returns `{status, adapter_mode}`.
- `GET /health/adapter` (API-key gated) returns `{adapter_mode, refresh_token_valid, active_stream_sessions, ring_api_requests_last_minute}`.
- Adapter operations emit structured records with `request_id`, `mode()`, `operation`, `device_id`, and outcome (`ok`/`upstream_error`/`adapter_error`/`timeout`).
- SIP/RTSP lifecycle emits `sip_established`, `sip_terminated`, `rtsp_publish_started`, `rtsp_publish_stopped` with `session_id` and `device_id`.

### Quality-of-life

- Live-capture fallback for snapshots: if Ring returns 404 on the cached image, the client issues `PUT /clients_api/snapshots/update_all {doorbot_ids, refresh: true}` to trigger a fresh capture, settles briefly, then re-GETs.
- `is_camera_kind()` filter in `list_devices` keeps doorbells / floodlights / spotlights / cams and hides chimes / beams / keypads / sensors; permissive allow-list so new Ring products surface by default.
- `scripts/bootstrap_ring_refresh_token.py` — single-command flow that runs the Ring OAuth 2FA dance, upserts `.env`, drops the invalidated token from the store, recreates the backend, and reports `refresh_token_valid` from `/health/adapter`. Token never printed to stdout.
- `docker compose up` defaults to mock mode; `docker compose --profile mock up` additionally brings up the ffmpeg test-pattern publisher.

### Testing

10 property-based tests plus focused examples and integration regressions:

| # | Property                                                           | Requirements |
|---|--------------------------------------------------------------------|--------------|
| 1 | Mock adapter equivalent to pre-refactor routes                     | 2.1–2.8, 13.4 |
| 2 | Adapter errors map to stable HTTP responses                        | 1.8, 11.2, 11.3 |
| 3 | Refresh token round-trip and rotation preserves ciphertext secrecy | 3.1, 3.2, 3.5, 9.1, 9.7, 13.6 |
| 4 | Access-token refresh threshold                                     | 3.3, 3.4 |
| 5 | Rate limit governor enforces rolling 60s window                    | 8.1, 8.2 |
| 6 | No plaintext secrets in log output                                 | 3.8, 9.2, 9.5 |
| 7 | Single adapter instance across requests                            | 1.7, 7.3 |
| 8 | `/mock/*` routes are thin delegators                               | 7.4, 12.5, 13.1 |
| 9 | Device/event mapping conforms to contract                          | 4.1, 4.2, 4.3, 4.4 |
| 10 | Stream session lifecycle invariants                                | 6.4, 6.5, 6.7 |

Full suite: **119 passed** (`uv run pytest`). Lint clean (`uv run ruff check .`). Node sidecar tests green (`npm test` inside `ring-sip-bridge/`).

### Verified live

Ran the stack in unofficial mode against a personal Ring account:

- Device list via `GET /mock/devices` returns 6 real cameras after filtering chimes.
- Snapshot via `POST /mock/devices/<id>/media/image/download` returns real JPEGs (24–64 KB) for every camera, including one that initially 404'd and was recovered via the `update_all` refresh.
- Backend `/health/adapter`: `refresh_token_valid: true`, `ring_api_requests_last_minute` climbing under load.
- No plaintext token appeared in captured logs at any point.

### PR stack position: 6 of 6

`main ← 1 ← 2 ← 3 ← 4 ← 5 ← **6**`

### Dependencies

- Requires **PRs #1–#5** to be merged first (or reviewed as a stack).
