# Release Notes

## v1.2 — Camera Snapshot Thumbnails

### Camera Snapshots

- Dashboard device cards now display the camera's latest snapshot as the card background (16:9 aspect-fill)
- Snapshots refresh automatically every 60 seconds while the dashboard is visible
- Player view shows the device's latest snapshot as a full-screen backdrop behind the "not yet supported" overlay (with 60% dark tint for text readability)
- Graceful fallback to placeholder icon when no snapshot is available

### Snapshot Service Architecture

- New `SnapshotService` protocol with `DefaultSnapshotService` implementation
- In-memory `NSCache` with 60-second TTL and 50MB size limit
- Actor-based request coalescing prevents duplicate API calls for the same device
- Rate limit handling (HTTP 429) — backs off silently until next refresh cycle
- Failure isolation — one device's snapshot failure doesn't block others

### Background App Refresh

- tvOS background app refresh pre-fetches snapshots for up to 10 devices every 15 minutes
- Snapshots are cached and ready when the user opens the app

### API Endpoints

- `POST /v1/devices/{device_id}/media/image/download` — Fetch latest cached JPEG snapshot via Partner API

### Codebase Cleanup

- Removed unused `snapshotURL: URL?` property from `RingDevice` model
- Updated doc comments referencing "HLS" to accurately describe "SIP/WebRTC" or "live stream sessions"

### Testing

- 5 unit tests for `DefaultSnapshotService` (cache hit/miss, stale cache, coalescing, rate limiting)
- 2 unit tests for `DashboardViewModel` snapshot integration
- 3 property-based tests (SwiftCheck) validating correctness properties:
  - CP-1: Cache freshness — stale entries always trigger fresh fetch
  - CP-2: Request coalescing — N concurrent requests produce exactly 1 API call
  - CP-3: Failure isolation — failing devices don't block others

---

## v1.1 — Ring API Compatibility & Dashboard Redesign

### Authentication

- Migrated to OAuth 2.0 Device Authorization Grant (RFC 8628) for account linking
- Device code flow: TV displays user code, user authorizes on phone/computer
- Proactive token refresh when within 60 seconds of expiry
- Secure Keychain storage for access and refresh tokens

### Ring Partner API Compatibility

- Migrated to Ring Partner API (Amazon Vision API at `api.amazonvision.com/v1`)
- Device discovery uses JSON:API format with string device IDs
- WHEP-based live streaming replaces SIP signaling
- `PartnerAPIError` replaces legacy error handling with rate-limit retry and proactive token refresh

### Dashboard Redesign

- Redesigned `DeviceCardView` to match the native Ring app style: snapshot-dominant 16:9 cards with overlaid device info
- Added green/red online status indicator dot
- Added device type icon (doorbell/camera) on each card
- Added battery level indicator with color coding
- Added gradient overlays for text readability over future snapshot images
- Added "Cameras" section header

### Project Structure

- Added `project.yml` for XcodeGen-based project generation (fixes "Recovered References" issue in Xcode)
- Regenerated `.xcodeproj` with proper folder group hierarchy

### Test Updates

- Updated all stream session tests for new WHEP-based model
- Updated error model tests for `PartnerAPIError` cases
- Updated API client tests for Partner API response format
- Updated retry strategy tests for new error signatures

---

## v1.0 — Initial Release

### Features

- **Authentication**: OAuth 2.0 Device Authorization Grant with account linking, automatic token refresh, secure Keychain storage
- **Device Dashboard**: Grid view of all Ring cameras and doorbells with online/offline status, filtering by name/type/status, sorting options, 60-second background refresh
- **Live Streaming**: WHEP-based stream session management with WebRTC
- **Event History**: Chronological event list (motion, doorbell press, on-demand), event video playback (requires Ring Protect), 50-event limit per device
- **tvOS Optimized**: Focus Engine navigation, 10-foot UI design, Siri Remote support, VoiceOver accessibility

### Architecture

- MVVM with protocol-based dependency injection
- SwiftUI targeting tvOS 15.0+
- Full mock infrastructure for testing

### Testing

- 80%+ overall code coverage
- 8 property-based test suites (SwiftCheck)
- Unit tests for all models, services, and ViewModels

### Known Limitations

- Stream sessions limited by device power source (30s battery / 60s line-powered)
- Event video requires Ring Protect subscription
- See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full details
