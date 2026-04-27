# Contributing

Thank you for your interest in contributing to the Apple TV Ring Camera Viewer.

## Code Style

- Follow the project's SwiftLint configuration (`.swiftlint.yml`)
- Use `///` doc comments on all public types, protocols, and non-trivial methods
- Follow MVVM separation: no business logic in Views, no UI logic in Services
- Use protocol-based dependency injection for all services
- Mark ViewModels with `@MainActor`

## Development Workflow

1. Fork the repository and create a feature branch from `main`
2. Make your changes with clear, focused commits
3. Ensure all existing tests pass (`Cmd + U` or `swift test`)
4. Add tests for new functionality:
   - Unit tests for models and services
   - Property-based tests for invariants (use SwiftCheck)
   - Mock-based tests for ViewModels
5. Run SwiftLint and fix any warnings: `cd RingAppleTV && swiftlint lint`
6. Open a pull request with a clear description of the change

## Pull Request Process

- PRs should target the `main` branch
- Include a description of what changed and why
- Reference any related issues
- Ensure CI passes (tests + linting)
- Keep PRs focused — one feature or fix per PR

## Testing Requirements

- Maintain 80%+ overall code coverage
- 90%+ coverage for the service layer
- 100% coverage for model decoding
- Add property-based tests for any new business logic invariants
- All mocks must implement the corresponding protocol and support call tracking

## Architecture Guidelines

- New services must define a protocol in `Services/Protocols/` and implementation in `Services/Implementations/`
- New views follow the existing folder structure under `Views/`
- Use `ViewState<T>` for all ViewModel state management
- Errors should propagate as `RingAPIError` and be mapped to user-friendly messages at the ViewModel layer
- For services that cache data, follow the `DefaultSnapshotService` pattern: inject dependencies via init, use `NSCache` for binary data or `CacheService` for `Codable` models
- Use Swift actors for thread-safe mutable state (see `InFlightStore` in `DefaultSnapshotService`)
- Background tasks should be registered in `BackgroundRefreshManager` and scheduled via `BGTaskScheduler`

## Documentation

- Update `RELEASE_NOTES.md` when adding user-facing features
- Update `KNOWN_ISSUES.md` when discovering limitations
- Add architecture docs in `docs/` for complex subsystems (see `docs/SNAPSHOT_ARCHITECTURE.md`)
- Include ASCII flow diagrams for non-trivial data flows

## Security

- Never log tokens, passwords, or sensitive data
- Store credentials only in the Keychain via `KeychainService`
- All network requests must use HTTPS
- Review error messages to avoid leaking technical details to the UI
