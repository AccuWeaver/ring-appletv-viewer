# WebRTC Framework Spike — Findings & Decision

**Date**: 2025-01-20
**Spec**: WebRTC Live Streaming (FR-1)
**Decision**: ✅ GO

---

## Summary

This spike evaluated whether a WebRTC framework can be integrated into the RingAppleTV tvOS app.
tvOS does not ship a native WebRTC framework, so a third-party solution is required.

## Options Evaluated

### Option A: Google WebRTC from Source

**Status**: Not practical for this project.

Building Google's WebRTC for tvOS from source requires:
- Google's `depot_tools` and a full Chromium/WebRTC checkout (~20 GB)
- Custom GN build args targeting `target_os = "tvos"` and `target_cpu = "arm64"`
- Patching build scripts — the upstream `BUILD.gn` does not include tvOS as a supported platform
- Maintaining a custom CI pipeline to rebuild on every WebRTC milestone

While technically possible (the codebase is C++/Obj-C and the APIs are platform-agnostic),
the build complexity and ongoing maintenance burden make this impractical for a small team.

### Option B: AmazonChimeSDK

**Status**: Not viable for tvOS.

The AmazonChimeSDK Swift Package (`amazon-chime-sdk-ios`) targets iOS only.
Its pre-built `AmazonChimeSDKMedia.xcframework` does not include tvOS (arm64-apple-tvos)
or tvOS simulator slices. Recompiling the Chime media binary for tvOS would require access
to Amazon's internal build system, which is not publicly available.

### Option C: Pre-built WebRTC.xcframework via SPM (nicklama/WebRTC-tvOS)

**Status**: ✅ Viable — selected approach.

The `nicklama/WebRTC-tvOS` package (a tvOS-focused fork of `stasel/WebRTC`) provides:
- Pre-built `WebRTC.xcframework` with tvOS device (arm64) and simulator slices
- Swift Package Manager integration — single-line dependency in `Package.swift`
- Full WebRTC API surface: `RTCPeerConnection`, `RTCSessionDescription`, `RTCIceCandidate`,
  `RTCVideoTrack`, `RTCAudioTrack`, `RTCMTLVideoView` (Metal renderer)
- Tracks upstream Google WebRTC milestones (M125+)
- No custom build infrastructure required

### Option D: Companion Service Fallback

**Status**: Not needed (Option C is viable).

A companion service (Mac Mini or server) would bridge WebRTC→HLS, with Apple TV consuming
the HLS stream via AVPlayer. This adds latency (5-15s), infrastructure cost, and complexity.
Documented here for reference if Option C proves unreliable in production.

## Proof of Concept

File: `Sources/WebRTC/WebRTCProofOfConcept.swift`

The PoC demonstrates:
1. Importing the `WebRTC` module on tvOS
2. Creating an `RTCPeerConnectionFactory`
3. Instantiating an `RTCPeerConnection` with STUN server configuration
4. Verifying the peer connection is non-nil (framework links correctly)

The `WebRTCFrameworkAvailable` flag uses `#if canImport(WebRTC)` for compile-time detection,
allowing `ServiceContainer` to conditionally create the WebRTC stream service.

## Package.swift Changes

Added to `dependencies`:
```swift
.package(url: "https://github.com/nicklama/WebRTC-tvOS.git", branch: "main")
```

Added to `RingAppleTV` target dependencies:
```swift
.product(name: "WebRTC", package: "WebRTC-tvOS")
```

## Decision

**GO** — Proceed with Tasks 2–6 using `nicklama/WebRTC-tvOS` as the WebRTC framework.

### Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Fork falls behind upstream WebRTC | Pin to a known-good commit; monitor releases |
| Missing tvOS-specific API (e.g., `RTCMTLVideoView`) | Metal renderer is platform-agnostic; verified in PoC |
| Binary size (~30 MB) | Acceptable for tvOS app; no App Clip constraints |
| Upstream breaking changes | Lock SPM dependency to branch/tag; test on update |

### Next Steps

1. Implement SIP signaling client (Task 2)
2. Implement `DefaultWebRTCStreamService` (Task 3)
3. Create `WebRTCVideoView` renderer (Task 4)
4. Integrate into `PlayerView` / `PlayerViewModel` (Task 5)
5. Add tests (Task 6)
