# Camera Snapshots — Tasks

## Task 1: Codebase cleanup — remove snapshotURL and fix HLS references

- [x] 1.1 Remove `snapshotURL: URL?` property from `RingDevice` struct
- [x] 1.2 Remove `snapshotURL: nil` from `RingDeviceResponse.toDomain()`
- [x] 1.3 Remove `snapshotURL: nil` from all device instances in `MockData`
- [x] 1.4 Remove `if device.snapshotURL == nil` check in `DeviceCardView.snapshotArea` (will be replaced in Task 5)
- [x] 1.5 Update `RingAPIClientProtocol` doc comment from "HLS" to "SIP/WebRTC" on `requestLiveStream`
- [x] 1.6 Update `VideoServiceProtocol` doc comment from "HLS" to "live stream sessions"
- [x] 1.7 Update `DefaultVideoService` class doc comment from "HLS" to "live stream sessions"
- [x] 1.8 Verify project compiles after all removals

## Task 2: Add snapshot API endpoints to RingAPIClient

- [x] 2.1 Add `fetchSnapshot(deviceId: Int, token: String) async throws -> Data` to `RingAPIClient` protocol
- [x] 2.2 Add `requestSnapshot(deviceId: Int, token: String) async throws` to `RingAPIClient` protocol
- [x] 2.3 Add a `performRaw(_ request: URLRequest) async throws -> Data` private helper to `DefaultRingAPIClient` that returns raw response data (not JSON-decoded), with the same HTTP status code mapping
- [x] 2.4 Implement `fetchSnapshot` in `DefaultRingAPIClient`: GET to `/clients_api/snapshots/image/{deviceId}` using `performRaw`, returns JPEG `Data`
- [x] 2.5 Implement `requestSnapshot` in `DefaultRingAPIClient`: POST to `/clients_api/doorbots/{deviceId}/snapshot` (fire-and-forget, no response body)
- [x] 2.6 Handle 404 (no snapshot available) and 429 (rate limited) responses appropriately

## Task 3: Create SnapshotService

- [x] 3.1 Define `SnapshotService` protocol in `Services/Protocols/SnapshotServiceProtocol.swift` with `getSnapshot(for:)`, `requestNewSnapshot(for:)`, `clearCache()`
- [x] 3.2 Implement `DefaultSnapshotService` in `Services/Implementations/DefaultSnapshotService.swift`:
  - Inject `AuthService` and `RingAPIClient` (follows existing service pattern)
  - `NSCache<NSNumber, CacheEntry>` with `CacheEntry` wrapping `NSData` + `Date` for TTL tracking
  - 60-second TTL per snapshot
  - `inFlightRequests: [Int: Task<Data, Error>]` dictionary for request coalescing
  - On 429 response, throw error without retry (caller handles silently)
- [x] 3.3 Wire `DefaultSnapshotService` into `ServiceContainer` and pass to `DashboardViewModel`

## Task 4: Update DashboardViewModel with snapshot support

- [x] 4.1 Add `snapshotService: SnapshotService` dependency to `DashboardViewModel` init
- [x] 4.2 Add `@Published var snapshots: [Int: Data]` dictionary
- [x] 4.3 Add `loadSnapshots(for:)` method that fetches snapshots for all devices in parallel using `TaskGroup`, updating `snapshots` dictionary
- [x] 4.4 Call `loadSnapshots` after `loadDevices()` succeeds
- [x] 4.5 Include snapshot refresh in the existing background refresh timer (refresh snapshots alongside device list)
- [x] 4.6 Handle individual snapshot failures silently (log but don't surface to user, don't affect other devices)

## Task 5: Update DeviceCardView to display snapshots

- [x] 5.1 Add `snapshotData: Data?` parameter to `DeviceCardView`
- [x] 5.2 When `snapshotData` is available, display as background image using `Image(uiImage:)` with `.resizable().aspectRatio(contentMode: .fill)` in the 16:9 card area
- [x] 5.3 Keep gradient overlays for text readability over real snapshot images
- [x] 5.4 Show placeholder camera icon when `snapshotData` is nil
- [x] 5.5 Update `DashboardView` to pass `viewModel.snapshots[device.id]` to each `DeviceCardView`

## Task 6: Update PlayerView to show snapshot backdrop

- [x] 6.1 Add `snapshotData: Data?` parameter to `PlayerView`
- [x] 6.2 In the SIP session branch, display snapshot as full-screen backdrop with aspect-fill and a dark tint overlay (`Color.black.opacity(0.6)`)
- [x] 6.3 Layer the existing "not yet supported" text and controls over the snapshot backdrop
- [x] 6.4 Fall back to solid black background when no snapshot is available
- [x] 6.5 Update `DashboardView`'s `playerViewBuilder` closure to pass snapshot data to `PlayerView`
- [x] 6.6 Update `ServiceContainer.makePlayerViewModel()` or the `playerViewBuilder` pattern as needed

## Task 7: Add background app refresh for snapshots

- [x] 7.1 Register for tvOS background app refresh in the app delegate or `@main` App struct
- [x] 7.2 In the background refresh handler, fetch device list then snapshots for up to 10 devices
- [x] 7.3 Store refreshed snapshots in the snapshot cache so they're ready on next foreground
- [x] 7.4 Call `BGTaskScheduler.submit` to schedule the next refresh

## Task 8: Add snapshot tests

- [x] 8.1 Add `fetchSnapshotResult` and `requestSnapshotResult` stubs to `MockRingAPIClient` with call tracking
- [x] 8.2 Create `MockSnapshotService` in `Tests/Mocks/` with configurable results
- [x] 8.3 Add sample JPEG `Data` to `MockData` (small valid JPEG bytes)
- [x] 8.4 Unit tests for `DefaultSnapshotService`: cache hit returns data without API call
- [x] 8.5 Unit tests for `DefaultSnapshotService`: cache miss triggers API call and caches result
- [x] 8.6 Unit tests for `DefaultSnapshotService`: stale cache (> 60s old) triggers fresh fetch
- [x] 8.7 Unit tests for `DefaultSnapshotService`: concurrent requests for same device coalesce into one API call
- [x] 8.8 Unit tests for `DefaultSnapshotService`: 429 response doesn't trigger immediate retry
- [x] 8.9 Unit tests for `DashboardViewModel`: snapshots dictionary populated after device load
- [x] 8.10 Unit tests for `DashboardViewModel`: individual snapshot failure doesn't block other devices

## Task 9: Add property-based tests for snapshot correctness

- [x] 9.1 Property test for CP-1 (Cache Freshness): for any sequence of get/wait/get operations, a cached result older than 60s is never returned without a fresh fetch
- [x] 9.2 Property test for CP-2 (Request Coalescing): for N concurrent requests for the same device, exactly 1 API call is made
- [x] 9.3 Property test for CP-3 (Failure Isolation): for any subset of devices that fail, all other devices still receive their snapshots
