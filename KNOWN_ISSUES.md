# Known Issues & Limitations

## Unofficial API

- This app uses Ring's private (reverse-engineered) API. Endpoints may change or break without notice.
- Authentication flow is based on community-documented OAuth endpoints; Ring may alter the flow at any time.
- 2FA support covers SMS/email codes only; hardware security keys are not supported.

## Streaming

- Live stream sessions have an API-imposed time limit (~10 minutes). The stream must be re-requested after expiration.
- Adaptive bitrate switching is handled by AVPlayer but quality depends on network conditions and Ring device capabilities.
- Simultaneous streams to the same device from multiple clients may cause conflicts.

## Event History

- Event video playback requires an active Ring Protect subscription. Without it, only event metadata (type, timestamp) is displayed.
- Event history is limited to the most recent 50 events per device.

## tvOS Limitations

- No background execution — the app cannot receive push notifications or run background tasks when not in the foreground.
- No picture-in-picture support for live streams on tvOS.
- Keychain items are not shared across devices (no iCloud Keychain sync on tvOS).

## Testing

- Property-based tests depend on SwiftCheck, which may have compatibility issues with future Swift versions.
- UI tests require manual verification on a physical Apple TV with Siri Remote for full focus engine coverage.

## Workarounds

| Issue | Workaround |
|-------|-----------|
| Stream expires mid-viewing | Use the retry button to request a new stream session |
| Device shows offline incorrectly | Pull to refresh or wait for the 60-second background refresh |
| Login fails after API change | Check community Ring API documentation for endpoint updates |
| Cache shows stale data | Force refresh bypasses the 5-minute cache TTL |

## Future Enhancements

- Support for Ring Protect video scrubbing and timeline navigation
- Multi-camera split-screen view
- Motion zone configuration
- Push notification support (if tvOS adds background capabilities)
- Snapshot thumbnails on device cards
- Settings view for runtime configuration (mock mode, debug logging, cache TTL)
- Analytics and crash reporting (local-only)
