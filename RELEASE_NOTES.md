# Release Notes

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
