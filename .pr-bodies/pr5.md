## Part 5 of 5 — docs, specs, publishing guide

### Specs (for traceability)
- `.kiro/specs/partner-auth-backend/` — requirements, design, tasks for the Python backend: OAuth flow, HMAC verification, encrypted token store.
- `.kiro/specs/ring-partner-api-migration/tasks.md` — updated to reflect what was actually built.
- `.kiro/specs/webrtc-streaming/tasks.md` — updated to reflect what was actually built.

### Documentation
- `docs/RING_APPSTORE_PUBLISHING.md` — step-by-step guide for Ring app-store credential provisioning and certification.
- `README.md`, `RELEASE_NOTES.md`, `KNOWN_ISSUES.md`, `CONTRIBUTING.md` — updated to describe the new partner-auth backend, Docker stack, and WebRTC flow.

### Dependencies
- Requires **PR #1–#4** to be merged first.

### PR stack position: 5 of 5
`main ← 1 ← 2 ← 3 ← 4 ← **5**`
