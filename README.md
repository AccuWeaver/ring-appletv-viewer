# Apple TV Ring Camera Viewer

A native tvOS application for viewing Ring camera live streams and recorded events on your Apple TV.

**Status**: v2.0 — Migrated to Ring Partner API (Amazon Vision API). OAuth 2.0 Device Authorization Grant authentication, JSON:API device discovery, WHEP live streaming, and camera snapshot thumbnails. Dashboard displays real camera snapshots with 60-second refresh.

## Screenshots

![Dashboard with Snapshots](docs/screenshots/dashboard-snapshots.png)
![Player View with Snapshot Backdrop](docs/screenshots/player-snapshot.png)

## Prerequisites

- Xcode 13.0+
- tvOS 15.0+ deployment target
- Apple TV (4th generation or later)
- Active Ring account with Ring cameras or video doorbells (linked via Device Authorization Grant)
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

## Local Development Stack (Docker)

For testing the full app flow without Ring Partner API credentials, the repo includes a Docker Compose stack that runs a mock Ring Partner API alongside a local WebRTC media server streaming a test pattern.

### Prerequisites

- Docker Desktop (or any Docker engine with Compose v2)

### Start the stack

```bash
docker compose up -d
```

This brings up three containers:

| Service | Port | Purpose |
|---|---|---|
| `backend` | 8000 | FastAPI auth backend + mock Ring Partner API endpoints |
| `mediamtx` | 8889 (WHEP), 8554 (RTSP) | WebRTC media server |
| `ffmpeg` | — | Continuously publishes a test video pattern to mediamtx |

### Useful commands

```bash
docker compose up -d               # start (or restart) the stack in background
docker compose logs -f             # tail all service logs
docker compose logs -f backend     # tail just the backend
docker compose ps                  # see container status
docker compose restart backend     # restart a single service
docker compose down                # stop and remove containers
docker compose down -v             # also wipe the persisted token database
```

### tvOS simulator

The simulator runs on the Mac itself, so it reaches the stack via `localhost`. Default `AppConfiguration.swift` already points there. Just run the app — you'll see mock devices on the dashboard, and clicking a camera plays an HLS test video (WebRTC video rendering is not supported on the tvOS simulator).

### Physical Apple TV

Your Apple TV needs the Mac's LAN IP. Run the helper script to get it:

```bash
./scripts/show-lan-ip.sh
```

Update `authBackendBaseURL` in `RingAppleTV/Sources/Models/AppConfiguration.swift` with that IP, then rebuild and deploy.

On a real device you'll see the ffmpeg test pattern streaming via real WebRTC through mediamtx.

### Switching to real Ring credentials

Once you have Ring Partner API credentials, set `useMocks: false` in `AppConfiguration.swift` and populate `authBackendAPIKey` with your backend's API key. The `PartnerAPIClient` will then hit Ring's production endpoints instead of the local mock.

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
│   │   ├── Protocols/         # Service interfaces (Auth, Device, Media, StreamSession, etc.)
│   │   └── Implementations/   # Production implementations
│   ├── ViewModels/      # Auth, Dashboard, Player, Events ViewModels
│   ├── Views/
│   │   ├── Authentication/    # Device code flow (OAuth 2.0 Device Authorization Grant)
│   │   ├── Dashboard/         # Camera grid + snapshot-backed device cards
│   │   ├── Events/            # Event history list
│   │   ├── Player/            # Video player (snapshot backdrop + WebRTC pending)
│   │   └── Shared/            # Loading, Error, EmptyState, RevealableSecureField
│   └── Utilities/       # Extensions, constants, rate limiting, retry
└── Tests/
    ├── Models/          # Model unit tests
    ├── Services/        # Service unit tests
    ├── ViewModels/      # ViewModel unit tests
    ├── Properties/      # SwiftCheck property-based tests
    ├── Mocks/           # Mock service implementations
    └── Helpers/         # Test utilities
```

## Architecture

MVVM with protocol-based dependency injection:

- **Views** — SwiftUI, focus management, no business logic
- **ViewModels** — `@MainActor`, `ObservableObject`, `ViewState<T>` state machine
- **Services** — Protocol-defined, injected via init, business logic layer
- **Infrastructure** — Partner API client, Keychain, file cache, snapshot cache

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
Partner API (POST /v1/devices/{id}/media/image/download)
    │
    ▼
PartnerAPIClient.downloadSnapshot() → raw JPEG Data
    │
    ▼
DefaultMediaService
    ├── NSCache (60s TTL, 50MB limit)
    ├── Actor-based request coalescing (prevents duplicate fetches)
    └── Auth token management (via AuthService)
    │
    ▼
DashboardViewModel.snapshots: [String: Data]
    │
    ├──▶ DeviceCardView (card background image)
    └──▶ PlayerView (full-screen backdrop behind overlay)
```

## Authentication

The app uses OAuth 2.0 Device Authorization Grant (RFC 8628) for account linking:

1. The app displays a user code and verification URL on the TV screen
2. The user opens the URL on their phone or computer and enters the code
3. The app polls the token endpoint until authorization completes
4. Tokens are stored securely in the tvOS Keychain with proactive refresh

## Troubleshooting

| Issue | Solution |
|-------|---------|
| Package resolution fails | File → Packages → Reset Package Caches, then resolve again |
| Simulator keyboard not working | Hardware → Keyboard → Connect Hardware Keyboard |
| Tests fail with keychain errors | Tests use mock keychain — ensure test target is selected |
| "No such module" errors | Clean build folder (`Cmd + Shift + K`), then rebuild |
| Xcode shows "Recovered References" | Regenerate project: `cd RingAppleTV && xcodegen generate` |
| Live stream fails | Check device online status and network connectivity. Battery devices have 30s session limit, line-powered 60s. |
| Snapshots not loading | Check network; Ring may rate-limit (429). Snapshots refresh every 60s automatically. |
| App Transport Security errors | The app enforces HTTPS-only; Ring API endpoints use HTTPS |
| Xcode hangs on open | Disable Xcode AI/Predictive Code Completion, clear derived data |

## Ring Protect Subscription

Event recordings require an active Ring Protect subscription. Without it, the app displays event timestamps and types but video playback for recorded events is unavailable.

## Disclaimer

This application uses the official Ring Partner API (Amazon Vision API). See [DISCLAIMER.md](DISCLAIMER.md) for details.

## License

This project is for personal, non-commercial use only.
