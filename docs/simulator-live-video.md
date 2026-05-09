# Live video on the tvOS simulator

WebRTC's Metal-backed video decoder does not render frames in the tvOS
simulator even when the connection succeeds. That's why the app gates
`StreamSessionManager` on `!targetEnvironment(simulator)`. This document
explains how to get *live* video flowing in the simulator by routing the
feed through a local proxy.

## Recommended path: go2rtc

[go2rtc] is a Go-based streaming proxy with a native Ring WebRTC client
written by the same author as the homebridge-ring plugin. It pulls Ring's
WebRTC feed directly (no ffmpeg SDP demuxer in the critical path) and
serves it as fMP4 HLS that AVPlayer can play natively.

[go2rtc]: https://github.com/AlexxIT/go2rtc

### 1. Wrap your Ring refresh token

go2rtc's Ring source expects the legacy base64'd AuthConfig envelope
rather than the raw JWT that `/oauth.ring.com` issues. We ship a wrapper
script that converts a JWT into the expected format:

```bash
echo "$RING_REFRESH_TOKEN" | uv run python scripts/wrap-ring-token.py
```

Copy the output into your root `.env`:

```dotenv
RING_REFRESH_TOKEN_G2R=<wrapped value>
```

Rotate the wrapper output any time you rotate your Ring refresh token.

### 2. Bring up the stack

The `go2rtc` container is part of `docker-compose.yml`. A fresh bring-up:

```bash
docker compose up -d --build
```

Verify go2rtc is healthy:

```bash
curl http://localhost:1984/api   # returns version info
```

### 3. Ask the backend for an HLS session

```bash
curl -X POST \
  http://localhost:8000/mock/devices/<camera_id>/media/streaming/hls/sessions
```

When `RING_REFRESH_TOKEN_G2R` is set, the backend's unofficial adapter
registers a `ring_<camera_id>` stream on go2rtc and returns a URL like:

```json
{
  "session_id": "…",
  "hls_url": "http://localhost:1984/api/stream.m3u8?src=ring_<camera_id>&mp4=flac"
}
```

That URL plays directly in the tvOS simulator's AVPlayer (the Player view
already consumes `hls_url` via `DefaultSimulatorLiveStreamService`).

### 4. Teardown

The existing `DELETE /mock/session/{session_id}` works for both
go2rtc-backed and mediamtx-backed HLS sessions. The app calls this
automatically when the player view disappears.

## Network caveats

go2rtc's Ring source is a **WebRTC client** — it makes outbound UDP
connections to Ring's Kinesis TURN/STUN endpoints. This works out of the
box on Linux with bridge networking. On macOS Docker Desktop some ISPs
NAT outbound UDP in ways that break the ICE handshake; if live streams
start but never emit bytes and `docker logs ring-go2rtc` shows no
`ice_connected` transition, try:

- Switching Docker Desktop's networking backend (Settings → Resources →
  Network → enable VZ or gRPC-fuse VirtioFS as applicable)
- Setting `network_mode: host` on the `go2rtc` service (Linux only)
- Port-forwarding 8555/udp explicitly on your router

The snapshot path (`ring_snap_<id>`) does *not* require WebRTC — it uses
Ring's REST JPEG endpoint — so if snapshots work but live does not, it's
an ICE problem, not an auth problem.

## Fallback path: ring-sip-bridge + mediamtx

When `RING_REFRESH_TOKEN_G2R` is unset, `create_hls_stream_session` falls
back to the original `ring-sip-bridge` sidecar which republishes Ring's
SIP/RTP as RTSP into `mediamtx`. That path is also present in the compose
stack for backward compatibility, but the go2rtc path is both simpler and
more reliable.

## Security

- `RING_REFRESH_TOKEN_G2R` is a capability token — anyone with it can
  subscribe to your live video feed. `.env` and `.env.local` are
  gitignored; keep it that way.
- Never set `log: level: trace` in `go2rtc.yaml`. TRACE echoes full
  request URLs, which include the wrapped refresh token.
- If you suspect a token has leaked (for example by being logged in an
  earlier trace run), regenerate it with `ring-auth-cli` and regenerate
  the wrapped form.
