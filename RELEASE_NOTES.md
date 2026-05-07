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

- `GET /clients_api/snapshots/image/{device_id}` — Fetch latest cached JPEG snapshot
- `POST /clients_api/doorbots/{device_id}/snapshot` — Request Ring to capture a new snapshot

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

### Authentication Fixes

- Fixed `2fa-support` header: was incorrectly sending the TOTP code as the header value instead of `"true"`
- Added 2FA method detection: parses `tsv_state` from Ring's 412 response to distinguish between SMS, TOTP (authenticator app), and email-based 2FA
- Shows method-appropriate prompt ("Enter the code from your authenticator app" vs "A verification code has been sent via SMS")
- Fixed bad 2FA code handling: HTTP 400 now maps to `twoFactorInvalid` instead of resetting the entire login flow
- Added `RevealableSecureField` custom component for tvOS password visibility without view-swap focus issues

### Ring API Compatibility

- Fixed device decoding: removed `features: [String: Bool]?` field from `RingDeviceResponse` — Ring's actual API returns a deeply nested object, not a flat dictionary
- Updated `StreamSession` and `StreamSessionResponse` to match Ring's actual SIP/WebRTC response format (was incorrectly expecting HLS URLs)
- `PlayerView` now shows an informational message about WebRTC requirement instead of crashing on missing HLS URL
- Added HTTP 400 → `twoFactorInvalid` error mapping in API client

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

- Updated all stream session tests for new SIP-based model
- Updated error model tests for `TwoFactorMethod` associated value
- Updated API client tests for corrected `2fa-support` header and SIP response format
- Updated retry strategy tests for new error signatures

---

## v1.0 — Initial Release

### Features

- **Authentication**: Email/password login with two-factor authentication, automatic token refresh, secure Keychain storage
- **Device Dashboard**: Grid view of all Ring cameras and doorbells with online/offline status, filtering by name/type/status, sorting options, 60-second background refresh
- **Live Streaming**: Stream session management (HLS assumed — corrected in v1.1)
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

- Uses Ring's unofficial private API (may break without notice)
- Stream sessions limited to ~10 minutes
- Event video requires Ring Protect subscription
- See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full details
