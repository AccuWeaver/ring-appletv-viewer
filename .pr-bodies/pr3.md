## Part 3 of 5 — vendor WebRTC.xcframework + build CI

Vendors Google's WebRTC framework (built from the stasel/WebRTC tvOS fork at AccuWeaver/WebRTC, branch `latest`) into the repo as an xcframework with two slices:
- `tvos-arm64` — device (Apple TV HD A8, Apple TV 4K A10/A12/A15)
- `tvos-arm64-simulator` — Apple Silicon Mac simulator

### CI workflows
Live in the fork repo (AccuWeaver/WebRTC):
- `.github/workflows/webrtc-build.yml` — build on push to `latest`
- `.github/workflows/webrtc-release.yml` — publish release artifact

The fork is included as a nested checkout (WebRTC submodule pointer) so the build inputs are co-located with the consumer app.

### Spec documents
`.kiro/specs/webrtc-tvos-fork/` documents the CI work that produced the xcframework.

### What's NOT in this PR
No Swift project wiring yet — that lands in **PR #4** (`feat(app)`) together with the client code that uses the framework.

### Dependencies
- Requires **PR #2** (mock API + Docker) to be merged first.

### PR stack position: 3 of 5
`main ← 1 ← 2 ← **3** ← 4 ← 5`
