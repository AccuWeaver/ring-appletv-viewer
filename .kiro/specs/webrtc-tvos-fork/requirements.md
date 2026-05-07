# Requirements Document

## Introduction

Fork the `stasel/WebRTC` Swift package to add tvOS platform support (device arm64 + simulator arm64/x86_64) to the pre-built `WebRTC.xcframework`. The RingAppleTV app currently depends on `stasel/WebRTC` for iOS/macOS WebRTC, but the upstream package does not include tvOS slices. The spike (see `SPIKE_FINDINGS.md`) confirmed that `nicklama/WebRTC-tvOS` provides a viable tvOS xcframework, but the project needs a maintained, self-controlled fork of `stasel/WebRTC` that includes tvOS slices alongside the existing iOS and macOS slices. This fork will be built and released via GitHub Actions CI, and the RingAppleTV `Package.swift` will point to the fork for all platforms.

## Glossary

- **Fork**: A GitHub repository cloned from `stasel/WebRTC` under the team's GitHub organization, with modifications to the CI pipeline and `Package.swift` to include tvOS support.
- **Upstream**: The original `stasel/WebRTC` repository that publishes pre-built WebRTC xcframeworks for iOS and macOS.
- **XCFramework**: An Apple bundle format that packages compiled binaries for multiple platforms and architectures into a single distributable artifact.
- **Slice**: A platform-architecture combination within an XCFramework (e.g., `tvos-arm64`, `tvossimulator-arm64-x86_64`).
- **GN_Build_Args**: The build configuration parameters used by Google's WebRTC build system (GN/Ninja) to target a specific platform and CPU architecture.
- **CI_Pipeline**: The GitHub Actions workflow that compiles WebRTC from source, assembles the XCFramework, and publishes release artifacts.
- **SPM**: Swift Package Manager, the dependency manager used by the RingAppleTV project.
- **RingAppleTV_Package**: The `Package.swift` file in the RingAppleTV project that declares dependencies and targets.
- **canImport_Guard**: The `#if canImport(WebRTC)` compile-time check in the RingAppleTV codebase that conditionally activates live streaming code when the WebRTC module is available.

## Requirements

### Requirement 1: Fork Repository Setup

**User Story:** As a developer, I want a fork of `stasel/WebRTC` under our GitHub organization, so that we control the build pipeline and release cadence for tvOS-compatible WebRTC xcframeworks.

#### Acceptance Criteria

1. THE Fork SHALL be created from the latest release tag of `stasel/WebRTC`.
2. THE Fork SHALL retain all existing iOS and macOS build targets from Upstream without modification.
3. THE Fork SHALL include a README section documenting the tvOS additions and how the Fork differs from Upstream.
4. THE Fork SHALL use the same versioning scheme as Upstream (milestone-based, e.g., `126.0.0`) with a tvOS suffix (e.g., `126.0.0-tvos.1`) to distinguish Fork releases.

### Requirement 2: CI Pipeline tvOS Build Configuration

**User Story:** As a developer, I want the GitHub Actions CI to build WebRTC for tvOS device and simulator targets, so that tvOS slices are included in every release.

#### Acceptance Criteria

1. THE CI_Pipeline SHALL build a tvOS device binary targeting `arm64` architecture.
2. THE CI_Pipeline SHALL build a tvOS simulator binary targeting both `arm64` and `x86_64` architectures.
3. THE CI_Pipeline SHALL use GN_Build_Args `target_os = "ios"` and `target_cpu = "arm64"` with tvOS SDK sysroot overrides for the device build, consistent with the approach documented by `swarm-cloud/Apple-WebRTC`.
4. THE CI_Pipeline SHALL use GN_Build_Args `target_os = "ios"` with tvOS simulator SDK sysroot overrides for the simulator build.
5. IF the tvOS device build fails, THEN THE CI_Pipeline SHALL fail the workflow run and report the build error in the GitHub Actions log.
6. IF the tvOS simulator build fails, THEN THE CI_Pipeline SHALL fail the workflow run and report the build error in the GitHub Actions log.

### Requirement 3: XCFramework Assembly with tvOS Slices

**User Story:** As a developer, I want the tvOS device and simulator binaries included in the `WebRTC.xcframework`, so that a single framework artifact supports iOS, macOS, and tvOS.

#### Acceptance Criteria

1. THE CI_Pipeline SHALL produce a single `WebRTC.xcframework` that contains slices for iOS device, iOS simulator, macOS, tvOS device, and tvOS simulator.
2. THE CI_Pipeline SHALL use `xcodebuild -create-xcframework` to assemble all platform slices into the XCFramework.
3. WHEN the XCFramework is assembled, THE CI_Pipeline SHALL verify that the tvOS device Slice (`tvos-arm64`) is present in the output.
4. WHEN the XCFramework is assembled, THE CI_Pipeline SHALL verify that the tvOS simulator Slice (`tvossimulator-arm64-x86_64`) is present in the output.
5. IF any Slice is missing from the assembled XCFramework, THEN THE CI_Pipeline SHALL fail the workflow run with a descriptive error message identifying the missing Slice.

### Requirement 4: Release Publishing

**User Story:** As a developer, I want the Fork to publish GitHub releases with the tvOS-inclusive xcframework, so that SPM can resolve the binary dependency.

#### Acceptance Criteria

1. WHEN a new version tag is pushed to the Fork, THE CI_Pipeline SHALL create a GitHub release with the `WebRTC.xcframework.zip` attached as a release asset.
2. THE CI_Pipeline SHALL compute a SHA-256 checksum of the `WebRTC.xcframework.zip` and include the checksum in the release notes.
3. THE Fork SHALL update the `Package.swift` binary target URL and checksum to point to the new release asset for each release.
4. WHEN a release is published, THE Fork SHALL ensure the SPM `Package.swift` declares support for `.tvOS(.v15)` in the `platforms` array.

### Requirement 5: RingAppleTV Package Integration

**User Story:** As a developer, I want the RingAppleTV `Package.swift` to point to the Fork instead of `stasel/WebRTC`, so that the tvOS build resolves the WebRTC dependency and live streaming activates automatically.

#### Acceptance Criteria

1. THE RingAppleTV_Package SHALL replace the `stasel/WebRTC` dependency URL with the Fork repository URL.
2. THE RingAppleTV_Package SHALL add `.tvOS` to the platform condition for the WebRTC product dependency (currently limited to `.iOS` and `.macOS`).
3. WHEN the RingAppleTV target is built for tvOS, THE SPM SHALL resolve and link the WebRTC framework from the Fork.
4. WHEN the WebRTC module is available on tvOS, THE canImport_Guard SHALL evaluate to `true`, activating the live streaming code paths.
5. WHEN the RingAppleTV target is built for iOS or macOS, THE SPM SHALL continue to resolve and link the WebRTC framework without regression.

### Requirement 6: Upstream Sync Process

**User Story:** As a developer, I want a documented process for syncing the Fork with new Upstream releases, so that the Fork stays current with WebRTC milestone updates.

#### Acceptance Criteria

1. THE Fork SHALL include a documented procedure (in `CONTRIBUTING.md` or `SYNC.md`) describing how to merge new Upstream release tags into the Fork.
2. THE documented procedure SHALL include steps to verify that tvOS slices build successfully after merging Upstream changes.
3. THE documented procedure SHALL include steps to run the CI_Pipeline and validate the XCFramework output before publishing a new Fork release.
4. THE documented procedure SHALL specify how to resolve merge conflicts in CI workflow files that differ between the Fork and Upstream.

### Requirement 7: Build Validation

**User Story:** As a developer, I want automated validation that the produced xcframework works correctly on tvOS, so that broken builds are caught before release.

#### Acceptance Criteria

1. THE CI_Pipeline SHALL include a validation step that imports the WebRTC module in a minimal tvOS target and compiles successfully.
2. THE CI_Pipeline SHALL verify that `RTCPeerConnectionFactory` can be instantiated in the tvOS validation target.
3. IF the tvOS validation step fails, THEN THE CI_Pipeline SHALL fail the workflow run and prevent the release from being published.
4. THE CI_Pipeline SHALL run the validation step on both tvOS device and tvOS simulator destinations.
