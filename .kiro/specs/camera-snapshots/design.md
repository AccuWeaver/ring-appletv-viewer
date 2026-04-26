# Camera Snapshots — Design Document

**Feature Name**: Camera Snapshots
**Version**: 2.0
**Last Updated**: April 2026

## Architecture

### Snapshot Pipeline

```text
RingAPIClient.fetchSnapshot(deviceId:token:) → Data (JPEG)
    ↓
DefaultSnapshotService (injects AuthService for token management)
    ↓ checks NSCache → if fresh, return cached
    ↓ if stale/missing, fetches from API
    ↓ coalesces concurrent requests via in-flight dictionary
    ↓ stores in NSCache with timestamp
DashboardViewModel.snapshots: [Int: Data]
    ↓
DeviceCardView → displays snapshot as card background
PlayerView → displays snapshot behind "not yet supported" overlay
```

## Components

### New API Client Methods

Add to `RingAPIClient` protocol:

```swift
/// Fetch the latest cached snapshot image for a device.
func fetchSnapshot(deviceId: Int, token: String) async throws -> Data

/// Request Ring to capture a new snapshot (rate-limited by Ring).
func requestSnapshot(deviceId: Int, token: String) async throws
```

Implementation in `DefaultRingAPIClient`:
- `fetchSnapshot`: GET to `/clients_api/snapshots/image/{deviceId}`, returns raw `Data` (not JSON-decoded). Needs a new `performRaw` helper that returns `Data` directly instead of decoding JSON.
- `requestSnapshot`: POST to `/clients_api/doorbots/{deviceId}/snapshot`, fire-and-forget (no response body needed).
- Both use Bearer token auth.

### New Protocol: `SnapshotService`

```swift
protocol SnapshotService {
    /// Fetch the latest snapshot for a device. Returns cached if fresh (< 60s).
    func getSnapshot(for deviceId: Int) async throws -> Data

    /// Request Ring to capture a new snapshot. Subject to rate limiting.
    func requestNewSnapshot(for deviceId: Int) async throws

    /// Clear all cached snapshots.
    func clearCache()
}
```

### New Implementation: `DefaultSnapshotService`

```swift
final class DefaultSnapshotService: SnapshotService {
    private let authService: AuthService
    private let apiClient: RingAPIClient
    private let cache = NSCache<NSNumber, CacheEntry>()
    private var inFlightRequests: [Int: Task<Data, Error>] = [:]
    private let cacheTTL: TimeInterval = 60

    /// Wrapper to store data + fetch timestamp in NSCache.
    private class CacheEntry: NSObject {
        let data: NSData
        let fetchedAt: Date
        init(data: NSData, fetchedAt: Date) {
            self.data = data
            self.fetchedAt = fetchedAt
            super.init()
        }
    }
}
```

Key behaviors:
- `getSnapshot(for:)` checks cache first. If entry exists and `fetchedAt` is within `cacheTTL`, returns cached data.
- If cache miss or stale, checks `inFlightRequests[deviceId]`. If a request is already in flight, awaits it.
- Otherwise, creates a new `Task` that calls `apiClient.fetchSnapshot(...)`, stores it in `inFlightRequests`, and cleans up on completion.
- On 429 response, does not retry — throws a specific error that callers can handle silently.

### Updated `ServiceContainer`

```swift
// Add to ServiceContainer:
let snapshotService: SnapshotService

// In init:
let snapshotService: SnapshotService = DefaultSnapshotService(
    authService: authService,
    apiClient: apiClient
)
self.snapshotService = snapshotService

// Update DashboardViewModel init:
self.dashboardViewModel = DashboardViewModel(
    deviceService: deviceService,
    snapshotService: snapshotService,
    refreshInterval: configuration.deviceRefreshInterval
)
```

### Updated `DashboardViewModel`

```swift
// New dependency:
private let snapshotService: SnapshotService

// New published state:
@Published var snapshots: [Int: Data] = [:]

// After loadDevices() succeeds:
await loadSnapshots(for: devices)

// In background refresh:
// Refresh snapshots alongside device refresh

// New method:
private func loadSnapshots(for devices: [RingDevice]) async {
    await withTaskGroup(of: (Int, Data?).self) { group in
        for device in devices {
            group.addTask { [snapshotService] in
                let data = try? await snapshotService.getSnapshot(for: device.id)
                return (device.id, data)
            }
        }
        for await (deviceId, data) in group {
            if let data {
                snapshots[deviceId] = data
            }
        }
    }
}
```

### Updated `DeviceCardView`

```swift
struct DeviceCardView: View {
    let device: RingDevice
    let snapshotData: Data?  // New parameter

    // In snapshotArea:
    // If snapshotData != nil, create UIImage and display with .resizable().aspectRatio(contentMode: .fill)
    // Otherwise show existing placeholder
}
```

### Updated `DashboardView`

Pass snapshot data when creating each card:

```swift
DeviceCardView(
    device: device,
    snapshotData: viewModel.snapshots[device.id]
)
```

### Updated `PlayerView`

In the SIP session branch, add snapshot backdrop:

```swift
if session.isSipSession {
    ZStack {
        // Snapshot backdrop (if available)
        if let snapshotData = snapshotData,
           let uiImage = UIImage(data: snapshotData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(Color.black.opacity(0.6))
        }

        // Existing "not yet supported" overlay
        VStack(spacing: 24) { ... }
    }
}
```

`PlayerView` will need a `snapshotData: Data?` parameter, passed from the dashboard via the `playerViewBuilder` closure.

### Codebase Cleanup

- Remove `snapshotURL: URL?` from `RingDevice`
- Remove `snapshotURL: nil` from `RingDeviceResponse.toDomain()`
- Remove `snapshotURL: nil` from all `MockData` device instances
- Remove `if device.snapshotURL == nil` check in `DeviceCardView` (replace with `snapshotData` check)
- Update `RingAPIClientProtocol` doc comment: "Request an HLS live stream" → "Request a live stream session (SIP/WebRTC)"
- Update `VideoServiceProtocol` doc comment: "Requests and validates HLS live stream sessions" → "Requests and validates live stream sessions"
- Update `DefaultVideoService` class doc comment similarly

## Data Flow

### Snapshot Fetch Sequence

1. `DashboardViewModel.loadDevices()` completes with device list
2. `DashboardViewModel.loadSnapshots(for:)` fires concurrently for all devices
3. For each device, `snapshotService.getSnapshot(for: device.id)` is called
4. `DefaultSnapshotService` checks NSCache → if fresh entry exists, returns it
5. If stale/missing, checks `inFlightRequests` → if request in flight, awaits it
6. Otherwise creates new fetch task via `apiClient.fetchSnapshot(deviceId:token:)`
7. Stores result in cache with current timestamp, removes from `inFlightRequests`
8. `DashboardViewModel` updates `snapshots` dictionary
9. `DeviceCardView` renders snapshot as card background

### Background Refresh Sequence

1. tvOS triggers background app refresh
2. App fetches device list, then snapshots for up to 10 most recently viewed devices
3. Results stored in cache so they're ready when user opens the app

## Error Handling

| Scenario | Behavior |
| --- | --- |
| Snapshot fetch fails (network) | Show placeholder, retry on next 60s refresh cycle |
| Snapshot 404 | Camera has no snapshot — show placeholder, don't retry until next cycle |
| Snapshot 429 (rate limited) | Back off silently, retry on next refresh cycle |
| Snapshot decode failure | Show placeholder (data isn't valid JPEG) |
| Auth token expired during fetch | `AuthService.getValidToken()` handles refresh automatically |

## Testing Strategy

### Unit Tests

- `DefaultSnapshotService`: cache hit returns data without API call
- `DefaultSnapshotService`: cache miss triggers API call and caches result
- `DefaultSnapshotService`: stale cache (> 60s) triggers fresh fetch
- `DefaultSnapshotService`: concurrent requests for same device coalesce into one API call
- `DefaultSnapshotService`: 429 response doesn't trigger immediate retry
- `DashboardViewModel`: snapshots dictionary populated after device load
- `DashboardViewModel`: individual snapshot failure doesn't affect other devices

### Property-Based Tests

- **CP-1 (Cache Freshness)**: For any sequence of get/wait/get operations, a cached result older than 60s is never returned without a fresh fetch.
- **CP-2 (Request Coalescing)**: For N concurrent requests for the same device, exactly 1 API call is made.
- **CP-3 (Failure Isolation)**: For any subset of devices that fail, all other devices still receive their snapshots.
