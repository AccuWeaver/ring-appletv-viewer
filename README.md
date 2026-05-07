# Apple TV Ring Camera Viewer

A native tvOS application for viewing Ring camera live streams and recorded events on your Apple TV.

**Status**: v1.2 — Authentication, device management, event history, and camera snapshot thumbnails working against Ring's live API. Live streaming pending WebRTC implementation. Dashboard displays real camera snapshots with 60-second refresh.

## Screenshots

![Dashboard with Snapshots](docs/screenshots/dashboard-snapshots.png)
![Player View with Snapshot Backdrop](docs/screenshots/player-snapshot.png)

## Prerequisites

- Xcode 13.0+
- tvOS 15.0+ deployment target
- Apple TV (4th generation or later)
- Active Ring account with Ring cameras or video doorbells
- Apple Developer account (for device deployment)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project file generation)
- [SwiftLint](https://github.com/realm/SwiftLint) (optional, for linting)

## Setup

1. Clone the repository:

   ```bash
   git clone <repository-url>
   cd ring-appletv-viewer
   ```

2. Generate the Xcode project:

   ```bash
   brew install xcodegen  # if not already installed
   cd RingAppleTV
   xcodegen generate
   ```

3. Open in Xcode:

   ```bash
   open RingAppleTV.xcodeproj
   ```

4. Resolve Swift Package Manager dependencies:
   - Xcode resolves packages automatically on open
   - If not: File → Packages → Resolve Package Versions

5. (Optional) Install SwiftLint:

   ```bash
   brew install swiftlint
   swiftlint lint
   ```

6. Set up git hooks:

   ```bash
   cd .. && git config core.hooksPath .githooks
   ```

## Build & Run

1. Select an Apple TV simulator target (e.g., Apple TV 4K)
2. `Cmd + R` to build and run
3. Use keyboard arrow keys and Enter to navigate in the simulator

For physical Apple TV: connect via USB-C or configure wireless debugging, then select as run destination.

## Project Generation

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` from `project.yml`. After adding new source files, regenerate:

```bash
cd RingAppleTV
xcodegen generate
```

This ensures proper Xcode group hierarchy matching the folder structure on disk.

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
├── project.yml          # XcodeGen spec
├── Info.plist
├── Sources/
│   ├── App/             # Entry point, ContentView, MainTabView, ServiceContainer,
│   │                    # BackgroundRefreshManager
│   ├── Models/          # AuthToken, RingDevice, RingEvent, StreamSession, errors
│   ├── Services/
│   │   ├── Protocols/         # Service interfaces (Auth, Device, Video, Snapshot, etc.)
│   │   └── Implementations/   # Production implementations
│   ├── ViewModels/      # Auth, Dashboard, Player, Events ViewModels
│   ├── Views/
│   │   ├── Authentication/    # Login + 2FA (with TOTP/SMS detection)
│   │   ├── Dashboard/         # Camera grid + snapshot-backed device cards
│   │   ├── Events/            # Event history list
│   │   ├── Player/            # Video player (snapshot backdrop + WebRTC pending)
│   │   └── Shared/            # Loading, Error, EmptyState, RevealableSecureField
│   └── Utilities/       # Extensions, constants, rate limiting, retry
└── Tests/
    ├── Models/          # Model unit tests
    ├── Services/        # Service unit tests (incl. DefaultSnapshotServiceTests)
    ├── ViewModels/      # ViewModel unit tests
    ├── Properties/      # SwiftCheck property-based tests (incl. SnapshotPropertyTests)
    ├── Mocks/           # Mock service implementations
    └── Helpers/         # Test utilities
```

## Architecture

MVVM with protocol-based dependency injection:

- **Views** — SwiftUI, focus management, no business logic
- **ViewModels** — `@MainActor`, `ObservableObject`, `ViewState<T>` state machine
- **Services** — Protocol-defined, injected via init, business logic layer
- **Infrastructure** — Ring API client, Keychain, file cache, snapshot cache

### Application Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RingAppleTVApp                                │
│  ┌──────────────────┐    ┌──────────────────────────────────────┐   │
│  │ ServiceContainer │───▶│ BackgroundRefreshManager              │   │
│  │  (DI root)       │    │  (pre-fetches snapshots every 15min) │   │
│  └────────┬─────────┘    └──────────────────────────────────────┘   │
│           │                                                          │
│  ┌────────▼─────────┐                                               │
│  │   MainTabView    │                                               │
│  │  ┌─────┐ ┌─────┐│                                               │
│  │  │Live │ │Event││                                               │
│  │  │ Tab │ │ Tab ││                                               │
│  │  └──┬──┘ └─────┘│                                               │
│  └─────┼────────────┘                                               │
│        │                                                             │
│  ┌─────▼──────────────────────────────────────────────────────────┐ │
│  │              DashboardView                                      │ │
│  │  ┌──────────────────────────────────────────────────────────┐  │ │
│  │  │  DashboardViewModel                                      │  │ │
│  │  │  • loadDevices() → fetchDevices → loadSnapshots(parallel)│  │ │
│  │  │  • snapshots: [Int: Data] (updated every 60s)            │  │ │
│  │  └──────────────────────────────────────────────────────────┘  │ │
│  │                                                                 │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐              │ │
│  │  │DeviceCard   │ │DeviceCard   │ │DeviceCard   │  ← snapshots │ │
│  │  │(snapshot bg)│ │(snapshot bg)│ │(placeholder)│    as card bg │ │
│  │  └──────┬──────┘ └─────────────┘ └─────────────┘              │ │
│  └─────────┼───────────────────────────────────────────────────────┘ │
│            │ tap                                                      │
│  ┌─────────▼───────────────────────────────────────────────────────┐ │
│  │              PlayerView                                          │ │
│  │  ┌────────────────────────────────────────────────────────────┐ │ │
│  │  │  Snapshot backdrop (aspect-fill + 60% dark overlay)        │ │ │
│  │  │  ┌──────────────────────────────────────────────────────┐  │ │ │
│  │  │  │  "Live streaming not yet supported" overlay          │  │ │ │
│  │  │  │  (WebRTC pending)                                    │  │ │ │
│  │  │  └──────────────────────────────────────────────────────┘  │ │ │
│  │  └────────────────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Snapshot Data Flow

```
Ring API (/clients_api/snapshots/image/{id})
    │
    ▼
DefaultRingAPIClient.fetchSnapshot() → raw JPEG Data
    │
    ▼
DefaultSnapshotService
    ├── NSCache (60s TTL, 50MB limit)
    ├── Actor-based request coalescing (prevents duplicate fetches)
    └── Auth token management (via AuthService)
    │
    ▼
DashboardViewModel.snapshots: [Int: Data]
    │
    ├──▶ DeviceCardView (card background image)
    └──▶ PlayerView (full-screen backdrop behind overlay)
```

## Authentication

The app supports Ring's two-factor authentication with automatic detection of the 2FA method:

- **TOTP (Authenticator app)** — Shows "Enter the code from your authenticator app"
- **SMS** — Shows "A verification code has been sent via SMS"
- **Email** — Shows "A verification code has been sent to your email"

The 2FA method is parsed from Ring's 412 response body (`tsv_state` field).

## Troubleshooting

| Issue | Solution |
|-------|---------|
| Package resolution fails | File → Packages → Reset Package Caches, then resolve again |
| Simulator keyboard not working | Hardware → Keyboard → Connect Hardware Keyboard |
| Tests fail with keychain errors | Tests use mock keychain — ensure test target is selected |
| "No such module" errors | Clean build folder (`Cmd + Shift + K`), then rebuild |
| Xcode shows "Recovered References" | Regenerate project: `cd RingAppleTV && xcodegen generate` |
| Live stream shows "not yet supported" | Ring uses WebRTC/SIP — HLS not available. WebRTC implementation planned. |
| Snapshots not loading | Check network; Ring may rate-limit (429). Snapshots refresh every 60s automatically. |
| App Transport Security errors | The app enforces HTTPS-only; Ring API endpoints use HTTPS |
| Xcode hangs on open | Disable Xcode AI/Predictive Code Completion, clear derived data |

## Ring Protect Subscription

Event recordings require an active Ring Protect subscription. Without it, the app displays event timestamps and types but video playback for recorded events is unavailable.

## Disclaimer

This is an unofficial application not affiliated with Ring LLC or Amazon.com, Inc. It uses Ring's private (reverse-engineered) API which may change without notice. For personal, educational, non-commercial use only. See [DISCLAIMER.md](DISCLAIMER.md) for details.

## License

This project is for personal, non-commercial use only.
