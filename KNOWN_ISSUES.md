# Known Issues & Limitations

## Unofficial API

- This app uses Ring's private (reverse-engineered) API. Endpoints may change or break without notice.
- Authentication flow is based on community-documented OAuth endpoints; Ring may alter the flow at any time.
- 2FA support covers SMS, email, and TOTP (authenticator app) codes. Hardware security keys are not supported.

## Live Streaming

- Ring uses SIP/WebRTC for live video streaming, not HLS. The app currently shows an informational message when attempting to view a live stream.
- WebRTC implementation for tvOS is planned (see `.kiro/specs/live-streaming/`).
- Stream sessions have an API-imposed time limit (~10 minutes via `expires_in`).
- Simultaneous streams to the same device from multiple clients may cause conflicts.

## Snapshots

- Snapshot images depend on Ring's server-side cache — if a camera hasn't captured a recent image, the API returns 404 and a placeholder is shown.
- Ring rate-limits snapshot requests (HTTP 429). The app backs off silently and retries on the next 60-second refresh cycle.
- Snapshots are cached in-memory only (`NSCache`). They don't persist across app launches — the background refresh task pre-fetches them every 15 minutes to mitigate cold starts.
- Under memory pressure, tvOS may evict cached snapshots. They'll be re-fetched on the next refresh cycle.

## Event History

- Event video playback requires an active Ring Protect subscription. Without it, only event metadata (type, timestamp) is displayed.
- Event history is limited to the most recent 50 events per device.

## tvOS Limitations

- Background app refresh is supported for snapshot pre-fetching (every 15 minutes), but the system controls when it actually runs.
- No picture-in-picture support for live streams on tvOS.
- Keychain items are not shared across devices (no iCloud Keychain sync on tvOS).
- Password field uses a custom `RevealableSecureField` since tvOS `SecureField` doesn't support inline reveal toggles.

## Xcode

- The `.xcodeproj` is generated via XcodeGen (`project.yml`). After adding new source files, run `xcodegen generate` from the `RingAppleTV/` directory.
- Xcode AI/Predictive Code Completion may cause Xcode to hang on project open. Disable it if you experience issues.

## Testing

- Property-based tests depend on SwiftCheck, which may have compatibility issues with future Swift versions.
- UI tests require manual verification on a physical Apple TV with Siri Remote for full focus engine coverage.

## Workarounds

| Issue | Workaround |
|-------|-----------|
| Live stream not available | WebRTC implementation pending — use Ring app for live viewing |
| Device shows offline incorrectly | Pull to refresh or wait for the 60-second background refresh |
| Snapshot shows placeholder | Camera may not have a recent image; wait for next refresh cycle |
| Login fails after API change | Check community Ring API documentation for endpoint updates |
| Cache shows stale data | Force refresh bypasses the 5-minute cache TTL |
| Xcode shows "Recovered References" | Run `cd RingAppleTV && xcodegen generate` to regenerate project |
| Xcode hangs on open | Disable Xcode AI, clear derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData/RingAppleTV-*` |

## Future Enhancements

- WebRTC live streaming (next major feature — planned)
- Multi-camera split-screen view
- Motion zone configuration
- Push notification support (if tvOS adds background capabilities)
- Settings view for runtime configuration
- Snapshot capture-on-demand (trigger new snapshot from the app)
