# Apple TV Ring Camera Viewer

A native tvOS application for viewing Ring camera live streams and recorded events on your Apple TV.

**Status**: v1.0 — Feature complete. Authentication, device management, live streaming, and event history are implemented and tested.

## Prerequisites

- Xcode 13.0+
- tvOS 15.0+ deployment target
- Apple TV (4th generation or later)
- Active Ring account with Ring cameras or video doorbells
- Apple Developer account (for device deployment)
- [SwiftLint](https://github.com/realm/SwiftLint) (optional, for linting)

## Setup

1. Clone the repository:

   ```bash
   git clone <repository-url>
   cd RingAppleTV
   ```

2. Open in Xcode:

   ```bash
   open RingAppleTV.xcodeproj
   ```

3. Resolve Swift Package Manager dependencies:
   - Xcode resolves packages automatically on open
   - If not: File → Packages → Resolve Package Versions
   - Package manifest: `RingAppleTV/Package.swift`

4. (Optional) Install SwiftLint:

   ```bash
   brew install swiftlint
   cd RingAppleTV && swiftlint lint
   ```

5. Set up git hooks:

   ```bash
   git config core.hooksPath .githooks
   ```

## Build & Run

1. Select an Apple TV simulator target (e.g., Apple TV 4K)
2. `Cmd + R` to build and run
3. Use keyboard arrow keys and Enter to navigate in the simulator

For physical Apple TV: connect via USB-C or configure wireless debugging, then select as run destination.

## Testing

Run all tests:

- Xcode: `Cmd + U`
- Command line: `cd RingAppleTV && swift test`

### Coverage Targets

| Layer | Target |
|-------|--------|
| Models | 100% |
| Services | 90%+ |
| ViewModels | 80%+ |
| Overall | 80%+ |

### Test Types

- **Unit tests** — XCTest-based, covering models, services, and ViewModels
- **Property-based tests** — SwiftCheck, verifying invariants across generated inputs (token persistence, device filtering/sorting, stream session validity, event ordering, error messages)
- **Mock infrastructure** — Protocol-based mocks for all services with configurable return values and call tracking

## Project Structure

```
RingAppleTV/
├── Package.swift
├── Info.plist
├── Sources/
│   ├── App/           # Entry point, ContentView, MainTabView, ServiceContainer
│   ├── Models/        # AuthToken, RingDevice, RingEvent, StreamSession, errors
│   ├── Services/
│   │   ├── Protocols/       # Service interfaces
│   │   └── Implementations/ # Production implementations
│   ├── ViewModels/    # Auth, Dashboard, Player, Events ViewModels
│   ├── Views/
│   │   ├── Authentication/  # Login + 2FA
│   │   ├── Dashboard/       # Camera grid + device cards
│   │   ├── Events/          # Event history list
│   │   ├── Player/          # HLS video player
│   │   └── Shared/          # Loading, Error, EmptyState views
│   └── Utilities/     # Extensions, constants, rate limiting, retry
└── Tests/
    ├── Models/        # Model unit tests
    ├── Services/      # Service unit tests
    ├── ViewModels/    # ViewModel unit tests
    ├── PropertyTests/ # SwiftCheck property-based tests
    ├── Mocks/         # Mock service implementations
    └── Helpers/       # Test utilities
```

## Architecture

MVVM with protocol-based dependency injection:

- **Views** — SwiftUI, focus management, no business logic
- **ViewModels** — `@MainActor`, `ObservableObject`, `ViewState<T>` state machine
- **Services** — Protocol-defined, injected via init, business logic layer
- **Infrastructure** — Ring API client, Keychain, file cache

## Troubleshooting

| Issue | Solution |
|-------|---------|
| Package resolution fails | File → Packages → Reset Package Caches, then resolve again |
| Simulator keyboard not working | Hardware → Keyboard → Connect Hardware Keyboard |
| Tests fail with keychain errors | Tests use mock keychain — ensure test target is selected |
| "No such module" errors | Clean build folder (`Cmd + Shift + K`), then rebuild |
| Stream playback fails in simulator | HLS streams require network access; use mock URLs for testing |
| App Transport Security errors | The app enforces HTTPS-only; Ring API endpoints use HTTPS |

## Ring Protect Subscription

Event recordings require an active Ring Protect subscription. Without it, the app displays event timestamps and types but video playback for recorded events is unavailable.

## Disclaimer

This is an unofficial application not affiliated with Ring LLC or Amazon.com, Inc. It uses Ring's private (reverse-engineered) API which may change without notice. For personal, educational, non-commercial use only. See [DISCLAIMER.md](DISCLAIMER.md) for details.

## License

This project is for personal, non-commercial use only.
