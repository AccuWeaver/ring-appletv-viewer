# Known Issues & Limitations

## Partner API

- This app uses the Ring Partner API (Amazon Vision API at `api.amazonvision.com/v1`).
- Authentication uses OAuth 2.0 Device Authorization Grant (RFC 8628) for account linking.
- Rate limit is 100 TPS per partner. The app handles 429 responses with retry and exponential backoff.

## Live Streaming

- Ring uses WHEP (WebRTC-HTTP Egress Protocol) for live video streaming via the Partner API.
- Stream sessions are limited by device power source: 30 seconds for battery-powered devices, 60 seconds for line-powered devices.
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
| Live stream not available | Check device online status and network connectivity |
| Device shows offline incorrectly | Pull to refresh or wait for the 60-second background refresh |
| Snapshot shows placeholder | Camera may not have a recent image; wait for next refresh cycle |
| Login fails | Check network connectivity and verify OAuth server is reachable |
| Cache shows stale data | Force refresh bypasses the 5-minute cache TTL |
| Xcode shows "Recovered References" | Run `cd RingAppleTV && xcodegen generate` to regenerate project |
| Xcode hangs on open | Disable Xcode AI, clear derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData/RingAppleTV-*` |

## Future Enhancements

- Multi-camera split-screen view
- Motion zone configuration
- Push notification support via webhook backend service
- Settings view for runtime configuration
