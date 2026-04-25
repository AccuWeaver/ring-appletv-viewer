# Apple TV Ring Camera Viewer

A native tvOS application for viewing Ring camera live streams and recorded events directly on your television.

## Prerequisites

- Xcode 13.0+
- tvOS 15.0+ deployment target
- Apple TV (4th generation or later)
- Active Ring account with Ring cameras or video doorbells
- Apple Developer account (for device deployment)
- [SwiftLint](https://github.com/realm/SwiftLint) for code linting (optional but recommended)

## Setup

1. Clone the repository:

   ```bash
   git clone <repository-url>
   cd RingAppleTV
   ```

2. Open the project in Xcode:

   ```bash
   open RingAppleTV.xcodeproj
   ```

3. Install SwiftLint (if not already installed):

   ```bash
   brew install swiftlint
   ```

   SwiftLint cannot be added as an SPM dependency — it must be installed separately via Homebrew. The project includes a `.swiftlint.yml` configuration at `RingAppleTV/.swiftlint.yml`. To lint the project manually:

   ```bash
   cd RingAppleTV
   swiftlint lint
   ```

4. Set up git hooks (SwiftLint + tests run on every commit):

   ```bash
   ./scripts/setup.sh
   ```

   Or manually:

   ```bash
   git config core.hooksPath .githooks
   ```

5. Resolve Swift Package Manager dependencies:
   - Xcode should resolve packages automatically on open
   - If not, go to File → Packages → Resolve Package Versions
   - The project uses `Package.swift` at `RingAppleTV/Package.swift`

## Build & Run

1. Select an Apple TV simulator target (e.g., Apple TV 4K) from the scheme selector
2. Press `Cmd + R` to build and run
3. Use keyboard arrow keys and Enter to navigate in the simulator

To deploy to a physical Apple TV, connect it via USB-C or configure wireless debugging, then select it as the run destination.

## Project Structure

```
RingAppleTV/
├── Package.swift                # SPM package manifest
├── Info.plist
├── RingAppleTV.entitlements
├── Sources/
│   ├── App/                     # App entry point and root views
│   │   ├── RingAppleTVApp.swift
│   │   └── ContentView.swift
│   ├── Models/                  # Data models (AuthToken, RingDevice, RingEvent, etc.)
│   ├── Services/
│   │   ├── Protocols/           # Service protocol definitions
│   │   └── Implementations/     # Concrete service implementations
│   ├── ViewModels/              # MVVM view models (@MainActor, ObservableObject)
│   ├── Views/
│   │   ├── Authentication/      # Login and 2FA views
│   │   ├── Dashboard/           # Camera grid and device cards
│   │   ├── Events/              # Event history list and rows
│   │   ├── Player/              # HLS video player
│   │   └── Shared/              # Reusable components (loading, error, empty states)
│   ├── Utilities/               # Extensions, constants, helpers
│   └── Resources/               # Assets and resources
└── Tests/
    ├── Models/                  # Model unit tests
    ├── Services/                # Service unit tests
    ├── ViewModels/              # ViewModel unit tests
    ├── PropertyTests/           # SwiftCheck property-based tests
    ├── Mocks/                   # Mock implementations for testing
    └── Helpers/                 # Test utilities and extensions
```

## Testing

Run the full test suite from Xcode:

- `Cmd + U` to run all tests
- Or use the Test Navigator (`Cmd + 6`) to run individual test classes

From the command line:

```bash
cd RingAppleTV
swift test
```

The project targets 80%+ overall code coverage, 90%+ for the service layer, and 100% for model decoding. Property-based tests use [SwiftCheck](https://github.com/typelift/SwiftCheck.git) to verify invariants across generated inputs.

## Ring Protect Subscription

Event recordings require an active Ring Protect subscription. Without it, the app will display event timestamps and types but video playback for recorded events will be unavailable.

## Disclaimer

This is an unofficial application and is not affiliated with, endorsed by, or connected to Ring LLC or Amazon.com, Inc. It uses Ring's private (reverse-engineered) API, which may change without notice.

This project is for personal, educational, non-commercial use only. It is not intended for App Store or public distribution. Use at your own risk — using unofficial APIs may violate Ring's Terms of Service.

## License

This project is for personal, non-commercial use only.
