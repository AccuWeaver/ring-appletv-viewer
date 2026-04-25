# Release Notes

## v1.0 — Initial Release

### Features

- **Authentication**: Email/password login with two-factor authentication (SMS/email codes), automatic token refresh, secure Keychain storage
- **Device Dashboard**: Grid view of all Ring cameras and doorbells with online/offline status, filtering by name/type/status, sorting options, 60-second background refresh
- **Live Streaming**: HLS live stream playback via AVPlayer, play/pause controls, session expiration handling with retry
- **Event History**: Chronological event list (motion, doorbell press, on-demand), event video playback (requires Ring Protect), 50-event limit per device
- **tvOS Optimized**: Focus Engine navigation, 10-foot UI design, Siri Remote support, VoiceOver accessibility

### Architecture

- MVVM with protocol-based dependency injection
- SwiftUI targeting tvOS 15.0+
- Full mock infrastructure for testing

### Testing

- 80%+ overall code coverage
- 8 property-based test suites (SwiftCheck) covering token persistence, device filtering/sorting, stream session validity, event ordering, and error messages
- Unit tests for all models, services, and ViewModels
- CI pipeline with automated testing

### Known Limitations

- Uses Ring's unofficial private API (may break without notice)
- Stream sessions limited to ~10 minutes
- Event video requires Ring Protect subscription
- See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full details
