# ring-sip-bridge

Small Node.js sidecar that wraps `ring-client-api`'s SIP negotiation behind a minimal HTTP control plane. Used by the Python backend (`partner-auth-backend`) when `RING_ADAPTER=unofficial`.

## Why a sidecar?

Ring's unofficial live-streaming protocol is SIP-over-WebSocket with proprietary quirks. `ring-client-api` (Node.js) implements the full state machine and has done so for years. Rather than port it to Python, we expose Ring SIP negotiation via HTTP and let the Python backend drive the lifecycle. Design discussion: see the `ring-adapter-backend` spec, §9 "Video Bridge Integration".

## HTTP contract

```text
POST /sessions
  body:   { "device_id": "<ring-device-id>", "refresh_token": "<...>" }
  201:    { "bridge_session_id": "<uuid>",
            "rtsp_path": "ring/<device_id>",
            "has_audio": true }
  400:    { "error": "device_id and refresh_token are required" }
  409:    { "error": "device_busy" }   — another active session for this device
  502:    { "error": "sip_failed", "detail": "..." }

DELETE /sessions/{bridge_session_id}
  204 (idempotent; unknown id still returns 204)

GET /sessions
  200: [ { bridge_session_id, device_id, state, started_at, has_audio }, ... ]

GET /health
  200: { "status": "ok", "active_sessions": <n> }
```

Refresh tokens are accepted per-request, used during `factory.start`, then discarded. They are never persisted to disk.

## Versions

- **Node**: 20.x (enforced via `package.json` `engines`)
- **HTTP**: [express](https://expressjs.com/) 4.21.2
- **Ring SIP**: [ring-client-api](https://github.com/dgreif/ring) 13.2.1 (pinned)
- **Tests**: [vitest](https://vitest.dev/) 2.1.9 + [supertest](https://github.com/ladjs/supertest) 7.0.0

Exact versions (no carets) per the ring-adapter-backend spec, Requirement 6.1.

## Local development

```bash
cd ring-sip-bridge
npm install
npm test
```

Tests run entirely offline. The production SIP factory (`createSessionFactory`) has a scaffolded stub where the real `ring-client-api` integration will live; tests inject `createTestSessionFactory` via `buildApp({ sessionFactory })` to drive every code path without touching the network.

## Docker

```bash
docker build -t ring-sip-bridge .
docker run --rm -p 3000:3000 -e MEDIAMTX_RTSP_URL=rtsp://mediamtx:8554/ring ring-sip-bridge
```

Image base is `node:20-slim`, runs as the non-root `node` user, exposes port 3000. The full stack is described in the repository's top-level `docker-compose.yml`.

## Directory layout

```text
ring-sip-bridge/
├── index.js               # Express app and session bookkeeping
├── session.js             # Pluggable SIP session factory (prod + test variants)
├── test/index.test.js     # Vitest + supertest suite
├── package.json           # Pinned deps, Node >=20, npm test = vitest run
├── Dockerfile             # node:20-slim, non-root
├── .gitignore / .dockerignore
└── README.md              # This file
```

## Status

The HTTP surface, session bookkeeping, watchdog, and test harness are complete and green. The real `ring-client-api` integration inside `createSessionFactory` is a separate manual task that requires a live Ring account — it's tracked outside this spec because it cannot be driven in CI.
