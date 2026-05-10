# go2rtc patches

Reproducible patches to upstream [go2rtc][] applied while bringing up
the tvOS simulator live-video path.

[go2rtc]: https://github.com/AlexxIT/go2rtc

## `client.go.patched` — Ring source with configurable ICE servers

Upstream's `pkg/ring/client.go` hard-codes the ICE server list for the
Ring WebRTC client. The patched version accepts two new query
parameters on the `ring:` source URL:

- `ice_servers` — JSON array of [`RTCIceServer`][rtc] objects. When
  present, these are **prepended** to the default STUN list (user-
  provided TURN tried first, default STUN retained as a fallback).
- `ice_transport_policy` — either `all` (default) or `relay`. Forcing
  `relay` requires ICE to use the supplied TURN server for every
  candidate, useful to verify TURN wiring works.

Additional debug scaffolding is gated on the `RING_DEBUG=1` env var and
prints every ICE candidate, SDP body, and peer-state transition. Never
enable `RING_DEBUG` with logs that ship off-host — the SDP bodies
contain the Ring session id, which is sensitive.

[rtc]: https://developer.mozilla.org/en-US/docs/Web/API/RTCIceServer

### Building

```bash
git clone --depth 1 https://github.com/AlexxIT/go2rtc.git .go2rtc-src
cp patches/go2rtc/client.go.patched .go2rtc-src/pkg/ring/client.go
cd .go2rtc-src && go build -o go2rtc .
```

`.go2rtc-src/` is git-ignored so the clone doesn't pollute the main
repo. The built binary can then be run from the host or packaged into
a container.

### Backend integration

The repo's `Go2rtcClient` passes the two new params through to go2rtc
when the corresponding env vars are set on the backend:

- `GO2RTC_RING_ICE_SERVERS` — JSON string (no escaping needed; backend
  appends it verbatim as a query-string value, httpx percent-encodes)
- `GO2RTC_RING_ICE_TRANSPORT_POLICY` — `relay` to force, empty for default

See `docs/simulator-live-video.md` for end-to-end setup with a local
coturn. A working coturn config lives at `.go2rtc-src/coturn.conf` in
the dev workflow (not checked in).

### Upstream-contribution status

This patch is a candidate for upstream. Before submitting:

1. Add unit tests for the new query-param parsing paths
2. Drop the `RING_DEBUG` scaffolding (the SDP dump leaks session info)
3. Document the new params in `internal/ring/README.md`

### Known remaining limitation

With the patch in place and a reachable TURN server, go2rtc reaches
pion `PeerConnectionState: connected` — ICE + DTLS succeed. Ring then
emits `camera_started` and the WS keepalive flows. But video RTP
packets from Ring's RMS never arrive at pion's selected candidate
pair. The stream times out without a first frame.

Hypothesis: Ring's RMS uses the media address it received during SDP
exchange, not the one ICE selected. Forcing TURN relay doesn't help
because Ring's side doesn't re-check which pair is active. Likely
needs a pion-side fix (explicit candidate pair pinning after
selection) or a Ring-side quirk we don't yet model.
