# Camera Snapshots — Requirements

**Feature Name**: Camera Snapshots
**Version**: 3.0
**Last Updated**: April 2026

## Overview

Display camera snapshot thumbnails on the dashboard device cards and show the latest snapshot as a backdrop in the player view (overlaid with a "not yet supported" message until WebRTC streaming is implemented separately). Ring provides snapshot endpoints that return the most recent camera image as JPEG data.

## Research Summary

1. **Snapshot API**: Ring provides a snapshot endpoint at `https://api.ring.com/clients_api/snapshots/image/{device_id}` that returns the most recent JPEG snapshot cached on Ring's servers.

2. **Rate Limiting**: Ring throttles snapshot requests — reports from `ring-client-api` and `ring-mqtt` suggest the GET fetch endpoint for the latest cached snapshot is less restricted than capture requests.

3. **Existing Codebase**: `RingDevice` already has a `snapshotURL: URL?` property, but it's always `nil` since `RingDeviceResponse.toDomain()` never populates it. The design will use a separate `snapshots: [Int: Data]` dictionary on the view model rather than the URL property, since we're fetching raw image data from the API (not loading from a URL). The unused `snapshotURL` property should be cleaned up.

## Functional Requirements

### FR-1: Snapshot Retrieval

- **FR-1.1**: System shall fetch the latest snapshot image for each camera device after the device list loads.
- **FR-1.2**: System shall cache snapshots in memory using `NSCache` with a 60-second TTL per device.
- **FR-1.3**: System shall refresh snapshots periodically (every 60 seconds) while the dashboard is visible.
- **FR-1.4**: System shall handle cameras that don't have a recent snapshot gracefully (show placeholder icon).
- **FR-1.5**: System shall not duplicate in-flight snapshot requests for the same device (coalesce concurrent fetches).
- **FR-1.6**: System shall handle rate-limited responses (HTTP 429) by backing off and retrying on the next refresh cycle, without surfacing errors to the user.

### FR-2: Snapshot Display on Dashboard

- **FR-2.1**: Dashboard device cards shall display the camera's latest snapshot as the card background.
- **FR-2.2**: Snapshots shall fill the 16:9 card area with aspect-fill scaling.
- **FR-2.3**: Gradient overlays shall ensure device name and status text remain readable over snapshot images.
- **FR-2.4**: Snapshot loading shall not block the dashboard from rendering (async image loading).
- **FR-2.5**: When no snapshot is available, the existing placeholder icon shall be shown.

### FR-3: Snapshot Display in Player View

- **FR-3.1**: When a SIP session is loaded, the player view shall display the device's latest snapshot as a full-screen backdrop behind the "not yet supported" overlay.
- **FR-3.2**: The snapshot shall be displayed with aspect-fill scaling and a dark tint overlay for text readability.
- **FR-3.3**: If no snapshot is available, the current solid black background shall be used.

### FR-4: Codebase Cleanup

- **FR-4.1**: Remove the unused `snapshotURL` property from `RingDevice` and all references to it.
- **FR-4.2**: Update doc comments on `RingAPIClientProtocol` and `VideoServiceProtocol` that incorrectly reference "HLS" — these should accurately describe SIP/WebRTC.

## Technical Requirements

### TR-1: Snapshot API Integration

- Fetch endpoint: `GET https://api.ring.com/clients_api/snapshots/image/{device_id}`
- Auth: Bearer token in Authorization header
- Response: Raw JPEG `Data`
- Error responses: 404 (no snapshot available), 429 (rate limited)

### TR-2: Image Caching

- Use a dedicated `NSCache<NSNumber, NSData>` for in-memory snapshot caching, **not** the existing file-based `CacheService`. Rationale:
  - Snapshots are raw JPEG `Data` blobs — wrapping them in JSON encoding/decoding (as `CacheService` does) adds unnecessary overhead
  - In-memory access is significantly faster than filesystem I/O, which matters when rendering thumbnails on dashboard cards
  - The 60-second TTL means disk persistence has no value (data would be expired on next launch anyway)
  - `NSCache` is thread-safe out of the box and auto-evicts under memory pressure, ideal for image data on memory-constrained tvOS
  - `CacheService` remains the right choice for structured `Codable` model data (devices, events) that benefits from surviving app restarts
- Cache TTL: 60 seconds (matches refresh interval)
- Maximum cache size: 50 MB
- Track timestamps per entry to determine freshness
- The OS may evict entries under memory pressure; treat eviction the same as expiry (re-fetch on next access)

### TR-3: Auth Pattern

- `SnapshotService` shall follow the existing service pattern: inject `AuthService` and call `authService.getValidToken()` internally, rather than requiring callers to pass tokens.

## Correctness Properties

### CP-1: Cache Freshness

- A snapshot returned from cache must have been fetched within the last 60 seconds. If the cached entry is older, a fresh fetch must be performed.

### CP-2: Request Coalescing

- If multiple callers request a snapshot for the same device while a network request is already in flight, no additional network request shall be made. All callers waiting on the same device shall receive the result of the single in-flight request.

### CP-3: Failure Isolation

- A snapshot fetch failure for one device must not prevent snapshots from loading for other devices.

### CP-4: Rate Limit Resilience

- When a 429 response is received, the system must not retry immediately. It must wait until the next scheduled refresh cycle.

## Reference Implementations

- `ring-client-api` (TypeScript): [github.com/dgreif/ring](https://github.com/dgreif/ring) — Snapshot API usage
- `python-ring-doorbell` (Python): [github.com/python-ring-doorbell/python-ring-doorbell](https://github.com/python-ring-doorbell/python-ring-doorbell) — Snapshot and event APIs
