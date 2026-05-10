# Live video on the tvOS simulator

WebRTC's Metal-backed video decoder does not render frames in the tvOS
simulator even when the connection succeeds. That's why the app gates
`StreamSessionManager` on `!targetEnvironment(simulator)`. This document
explains how to route the feed through a local proxy so AVPlayer can play
it instead.

## Architecture

The backend's unofficial adapter exposes `create_hls_stream_session` on
its route layer. When `RING_REFRESH_TOKEN_G2R` is set, that call:

1. Upserts a named `ring_<camera_id>` stream on a [go2rtc][] instance via
   its HTTP API (`PUT /api/streams`). Go2rtc has a native Ring WebRTC
   client that fetches the live feed directly — no ffmpeg SDP demuxer in
   the critical path.
2. Returns an HLS URL of the form
   `<public-go2rtc-url>/api/stream.m3u8?src=ring_<camera_id>&mp4=flac`
   that the tvOS client plays through AVPlayer.
3. Later teardown calls `DELETE /mock/session/{session_id}` which
   releases the go2rtc stream.

When `RING_REFRESH_TOKEN_G2R` is unset, the same route falls back to the
legacy `ring-sip-bridge + mediamtx` chain for backward compatibility.

[go2rtc]: https://github.com/AlexxIT/go2rtc

## Token wrapping (required once)

go2rtc's Ring source expects the legacy base64'd AuthConfig envelope
rather than the raw JWT that `oauth.ring.com` issues. The repo ships a
wrapper script:

```bash
echo "$RING_REFRESH_TOKEN" | uv run python scripts/wrap-ring-token.py
```

Copy the output into the root `.env` as `RING_REFRESH_TOKEN_G2R=…`.
Rotate the wrapper output any time you rotate the underlying Ring
refresh token.

## Running go2rtc

There are two ways to run go2rtc. Pick one based on your environment:

### In Docker (Linux / works for most macOS networks)

The bundled compose stack includes a `go2rtc` service, gated on the
`compose` profile so it doesn't start by default. If bridged Docker
networking happens to work for WebRTC on your machine:

```bash
docker compose --profile compose up -d --build
```

Verify it's up:

```bash
curl http://localhost:1984/api            # version info
curl http://localhost:1984/api/streams    # empty object, then populated
```

### On the host (reliable on macOS Docker Desktop)

Docker Desktop on macOS routes outbound UDP through a VM with
symmetric NAT. Ring's ICE handshake does not complete in that setup.
Running go2rtc directly on the host avoids the problem:

```bash
ARCH=$(uname -m)
case "$ARCH" in
  arm64) PKG=go2rtc_mac_arm64.zip ;;
  x86_64) PKG=go2rtc_mac_amd64.zip ;;
esac
mkdir -p .go2rtc-host && cd .go2rtc-host
curl -sLo go2rtc.zip "https://github.com/AlexxIT/go2rtc/releases/latest/download/$PKG"
unzip -oq go2rtc.zip && chmod +x go2rtc
cp ../go2rtc.yaml .
./go2rtc -config go2rtc.yaml
```

`.go2rtc-host/` is git-ignored. Leave the process running in its own
terminal.

Then point the backend at the host:

```dotenv
# in .env
GO2RTC_URL=http://host.docker.internal:1984
GO2RTC_PUBLIC_URL=http://localhost:1984
```

and bounce the backend:

```bash
docker compose up -d --force-recreate backend
```

## Verifying end-to-end

```bash
# kick a session through the backend
curl -X POST http://localhost:8000/mock/devices/<camera_id>/media/streaming/hls/sessions

# confirm go2rtc has the stream
curl http://localhost:1984/api/streams | jq keys

# pull the master playlist (succeeds once ICE completes and segments exist)
curl -IL 'http://localhost:1984/api/stream.m3u8?src=ring_<camera_id>&mp4=flac'
```

A 200 on the last command with a non-empty playlist means live video
will render in the simulator.

## Known constraint: Ring ICE / WebRTC

Ring's media is delivered over WebRTC using AWS Kinesis Video Streams
STUN/TURN. Go2rtc's Ring source hard-codes only STUN servers in its
`pkg/ring/client.go` ICE config and relies on Ring to send server-
reflexive candidates over the SIP-over-WebSocket channel. On some
networks (notably Docker Desktop VM networking on macOS and ISPs with
symmetric NAT), the ICE handshake does not complete — the Ring producer
starts, exchanges SDP, and then tears down within ~17 seconds without
ever reaching `ice_connected`.

Symptoms you'll see in `go2rtc` logs:

```
DBG [streams] start producer url=ring:?device_id=…
DBG [streams] stop producer  url=ring:?device_id=…  ← 15–20 s later
```

and on the app side:

```
WRN [hls] can't get init id=…
```

The snapshot path (`ring_snap_<id>` via `/api/frame.jpeg`) uses Ring's
REST JPEG endpoint and does NOT require WebRTC; it will still work even
when live does not. That's your debug probe: if snapshots work but live
does not, it is unambiguously an ICE problem, not an auth problem.

### Workarounds

- **Linux with `network_mode: host`**: most reliable. Add that stanza to
  the `go2rtc` service in `docker-compose.yml` when running on Linux.
- **Host go2rtc**: as above — bypasses Docker Desktop's VM networking.
- **TURN relay**: supported via the `GO2RTC_RING_ICE_SERVERS` and
  `GO2RTC_RING_ICE_TRANSPORT_POLICY` environment variables **when running
  a patched go2rtc build**. Upstream go2rtc hard-codes the ICE servers
  for its Ring source; the repo ships a patch under `.go2rtc-src/` (git-
  ignored) that adds `ice_servers` + `ice_transport_policy` query
  parameters. Build it with `go build -o go2rtc .` and run it alongside
  your TURN server (e.g. coturn) configured with long-term credentials.
  The patch plumbs values through as:

  ```json
  GO2RTC_RING_ICE_SERVERS=[{"urls":["turn:host:3478"],"username":"u","credential":"p"}]
  GO2RTC_RING_ICE_TRANSPORT_POLICY=relay
  ```

  Diagnostic status on macOS Docker Desktop: with a local coturn, ICE
  completes to `connected`, peer DTLS succeeds, Ring sends
  `camera_started`, and ping/pong keepalive flows — but video RTP
  packets from Ring never arrive at pion's selected candidate pair.
  Root cause is still under investigation; suspect a BUNDLE /
  candidate-pair reselection issue specific to pion's interaction with
  Ring's RMS (Ring Media Service). The patch is necessary for TURN, but
  not by itself sufficient.

## Security

- `RING_REFRESH_TOKEN_G2R` is a capability token — anyone with it can
  subscribe to your live video feed. Keep `.env` git-ignored.
- Do not set `log: level: trace` in `go2rtc.yaml` or the backend.
  TRACE echoes full request URLs, which include the wrapped refresh
  token. The backend has a `RedactingFilter` that scrubs URL query
  params for known-sensitive field names at INFO and above; go2rtc does
  not, so its own TRACE output will leak.
- The backend silences `httpx`'s info-level logs (which include outbound
  URLs) to WARNING as a belt-and-suspenders measure.
