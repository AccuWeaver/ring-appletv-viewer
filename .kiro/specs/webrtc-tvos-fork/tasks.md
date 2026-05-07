# Implementation Plan: WebRTC tvOS Fork

## Overview

Fork `stasel/WebRTC`, extend the CI build pipeline with tvOS device and simulator targets, produce a unified xcframework, and update the RingAppleTV `Package.swift` to consume the fork. Implementation uses Bash for build scripts, YAML for GitHub Actions workflows, Python for release automation, and Swift for package manifests and validation.

## Tasks

- [x] 0. Fork `stasel/WebRTC` repository
  - [x] 0.1 Fork `stasel/WebRTC` to your GitHub account/org via `gh repo fork stasel/WebRTC --clone`
  - [x] 0.2 Clone the fork locally (if not already done by `--clone`)
  - [x] 0.3 Set upstream remote to `stasel/WebRTC` for future syncs (`git remote add upstream https://github.com/stasel/WebRTC.git`)
  - [x] 0.4 Verify the fork is on the latest release tag
  - _Requirements: 1.1, 1.2_

- [x] 1. Create the `scripts/tvosify.sh` script
  - [x] 1.1 Create `scripts/tvosify.sh` that patches GN-generated Ninja files to target tvOS
    - Accept `<build_dir>` and `<environment>` (device/simulator) arguments
    - Resolve tvOS SDK path via `xcrun --sdk appletvos` or `xcrun --sdk appletvsimulator`
    - Resolve iOS SDK paths via `xcrun --sdk iphoneos` and `xcrun --sdk iphonesimulator`
    - Use `find` + `sed` to replace iOS SDK sysroot paths with tvOS SDK paths in all `.ninja` files
    - Replace `-miphoneos-version-min=*` and `-mios-simulator-version-min=*` flags with `-mtvos-version-min=15.0` or `-mtvos-simulator-version-min=15.0`
    - Make the script executable (`chmod +x`)
    - _Requirements: 2.1, 2.2, 2.3, 2.4_

- [x] 2. Modify `scripts/build.sh` to add tvOS support
  - [x] 2.1 Add `TVOS` environment variable toggle
    - Follow the existing pattern of `IOS`, `MACOS`, `MAC_CATALYST` boolean env vars
    - Default `TVOS` to `false`
    - _Requirements: 2.1, 2.2_
  - [x] 2.2 Implement `build_tvOS()` function
    - Accept `arch` and `environment` (device/simulator) parameters
    - Run `gn gen` with `target_os="ios"`, `target_cpu="${arch}"`, and common GN args
    - Call `scripts/tvosify.sh` to patch the generated build directory
    - Run `ninja -C` to compile `framework_objc`
    - Exit with error on build failure
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6_
  - [x] 2.3 Add tvOS build invocations to the main build flow
    - When `TVOS=true`, call `build_tvOS arm64 device` for tvOS device
    - When `TVOS=true`, call `build_tvOS arm64 simulator` for tvOS simulator (arm64 only)
    - _Requirements: 2.1, 2.2_
  - [x] 2.4 Extend xcframework assembly with tvOS slices
    - Add tvOS device slice (`tvos-arm64`, platform `tvos`) to the xcframework Info.plist via `PlistBuddy`
    - Add tvOS simulator slice (`tvos-arm64-simulator`, platform `tvos`, variant `simulator`) to the xcframework Info.plist
    - Copy tvOS framework binaries into the xcframework directory structure (no `lipo` needed — single arch per slice)
    - _Requirements: 3.1, 3.2, 3.3, 3.4_
  - [x] 2.5 Add post-assembly validation for tvOS slices
    - After xcframework assembly, verify `tvos-arm64/` directory exists
    - Verify `tvos-arm64-simulator/` directory exists
    - Fail with a descriptive error message identifying the missing slice if either is absent
    - _Requirements: 3.3, 3.4, 3.5_

- [x] 3. Checkpoint — Verify build script changes
  - Ensure all build script modifications are syntactically correct and consistent with existing patterns. Ask the user if questions arise.

- [x] 4. Modify GitHub Actions workflows
  - [x] 4.1 Update `.github/workflows/webrtc-build.yml` with tvOS input
    - Add `tvos` boolean input parameter (default `true`) to `workflow_dispatch` inputs
    - Pass `TVOS: ${{ inputs.tvos }}` as an environment variable to the build step
    - _Requirements: 2.1, 2.2_
  - [x] 4.2 Update `.github/workflows/webrtc-release.yml` for tvOS
    - Ensure `release.py` invocation sets `TVOS=true` in the build environment
    - No structural workflow changes needed — `release.py` handles platform flags
    - _Requirements: 4.1_

- [x] 5. Modify `scripts/release.py` to enable tvOS builds
  - Update `buildWebRTC()` to set `TVOS=true` alongside existing platform flags (`IOS`, `MACOS`, `MAC_CATALYST`)
  - Ensure checksum computation and release draft creation work with the larger xcframework
  - _Requirements: 4.1, 4.2_

- [x] 6. Create `scripts/validate_tvos.sh` validation script
  - [x] 6.1 Create the validation script
    - Accept xcframework path as argument
    - Write a minimal Swift file that `import WebRTC` and instantiates `RTCPeerConnectionFactory`
    - Compile against tvOS device SDK (`arm64-apple-tvos15.0`) using `xcrun swiftc`
    - Compile against tvOS simulator SDK (`arm64-apple-tvos15.0-simulator`) using `xcrun swiftc`
    - Exit non-zero if either compilation fails
    - Make the script executable
    - _Requirements: 7.1, 7.2, 7.3, 7.4_
  - [x] 6.2 Integrate validation into the build/release pipeline
    - Call `validate_tvos.sh` from `build.sh` after xcframework assembly when `TVOS=true`
    - Ensure `release.py` aborts before creating a GitHub release draft if validation fails
    - _Requirements: 7.3_

- [x] 7. Checkpoint — Verify CI pipeline changes
  - Ensure all workflow YAML, build script, and release script changes are consistent. Ask the user if questions arise.

- [x] 8. Update the fork's `Package.swift`
  - Add `.tvOS(.v15)` to the `platforms` array alongside existing `.iOS(.v12)` and `.macOS(.v10_11)`
  - Ensure the binary target URL and checksum placeholders are in place for `release.py` to update per release
  - _Requirements: 4.3, 4.4_

- [x] 9. Create `SYNC.md` upstream sync documentation
  - Document the procedure for merging new `stasel/WebRTC` release tags into the fork
  - Include steps to verify tvOS slices build successfully after merging upstream changes
  - Include steps to run the CI pipeline and validate xcframework output before publishing a new fork release
  - Specify how to resolve merge conflicts in CI workflow files and `build.sh` that differ between the fork and upstream
  - _Requirements: 6.1, 6.2, 6.3, 6.4_

- [x] 10. Update the fork's README with tvOS documentation
  - Add a section documenting the tvOS additions and how the fork differs from upstream
  - Document the `TVOS` env var toggle and the `tvosify.sh` script
  - Document the versioning scheme (same milestone numbers as upstream)
  - _Requirements: 1.3, 1.4_

- [x] 11. Update the RingAppleTV `Package.swift` to point to the fork
  - Replace the `stasel/WebRTC` dependency URL with the fork repository URL
  - Update the version requirement to match the fork's latest release (e.g., `from: "147.0.0"`)
  - Add `.tvOS` to the platform condition for the WebRTC product dependency (alongside `.iOS` and `.macOS`)
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_

- [x] 12. Checkpoint — Verify all changes and integration
  - Ensure all scripts, workflows, Package.swift files, and documentation are consistent and complete
  - Verify the RingAppleTV Package.swift correctly references the fork with tvOS platform support
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- This is primarily CI/build infrastructure work — the implementation involves shell scripts, YAML workflows, Python automation, and Swift package manifests
- The tvOS build uses a sysroot override approach (patching Ninja files) since WebRTC's GN build system does not natively support `target_os = "tvos"`
- The fork preserves the upstream manual xcframework assembly pattern (using `PlistBuddy` and `lipo`) rather than `xcodebuild -create-xcframework`
- Integration testing happens via the GitHub Actions CI pipeline itself — the build workflow IS the integration test
- Checkpoints ensure incremental validation of build script, CI pipeline, and integration changes
