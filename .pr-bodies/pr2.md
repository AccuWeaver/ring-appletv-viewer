## Part 2 of 5 — mock Ring partner API routes + Docker stack

Mock Ring Partner API endpoints on the partner-auth backend for offline testing of the tvOS app without real Ring credentials, plus Docker Compose stack for local dev.

### Mock endpoints
- `GET /mock/devices`
- `GET /mock/history/devices/{id}/events`
- `GET /mock/devices/{id}/media/image/download`
- `GET /mock/devices/{id}/media/video/download`
- `POST /mock/devices/{id}/media/streaming/whep/sessions`
- `DELETE /mock/session/{id}`

The WHEP endpoint proxies to a local mediamtx instance which republishes an ffmpeg test pattern, giving the Swift client a real SDP offer/answer exchange to validate the WHEP flow end-to-end.

### Docker Compose stack
- `backend` — Python/FastAPI (persistent volume for token DB)
- `mediamtx` — bluenviron/mediamtx:latest (RTSP in, WHEP out)
- `ffmpeg` — linuxserver/ffmpeg:latest (publishes testsrc2 pattern)
- All services: `restart: unless-stopped`

`scripts/show-lan-ip.sh` helper prints the host LAN IP so physical Apple TV devices (which can't reach localhost) can point at the dev Mac.

### Dependencies
- Requires **PR #1** (partner-auth backend) to be merged first.

### PR stack position: 2 of 5
`main ← 1 ← **2** ← 3 ← 4 ← 5`
