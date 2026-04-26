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

- Camera snapshot thumbnails are not yet displayed on dashboard cards (placeholder shown).
- Snapshot API integration is planned as Phase 1 of the live-streaming feature spec.

## Event History

- Event video playback requires an active Ring Protect subscription. Without it, only event metadata (type, timestamp) is displayed.
- Event history is limited to the most recent 50 events per device.

## tvOS Limitations

- No background execution — the app cannot receive push notifications or run background tasks when not in the foreground.
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
| Login fails after API change | Check community Ring API documentation for endpoint updates |
| Cache shows stale data | Force refresh bypasses the 5-minute cache TTL |
| Xcode shows "Recovered References" | Run `cd RingAppleTV && xcodegen generate` to regenerate project |
| Xcode hangs on open | Disable Xcode AI, clear derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData/RingAppleTV-*` |

## Future Enhancements

- Camera snapshot thumbnails on dashboard cards (Phase 1 — in progress)
- WebRTC live streaming (Phase 2 — planned)
- Multi-camera split-screen view
- Motion zone configuration
- Push notification support (if tvOS adds background capabilities)
- Settings view for runtime configuration
