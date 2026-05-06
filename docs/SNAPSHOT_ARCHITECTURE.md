# Camera Snapshots — Architecture & Data Flow

## Overview

The camera snapshots feature displays the latest camera image on dashboard device cards and as a backdrop in the player view. Snapshots are fetched from the Ring Partner API, cached in memory with a 60-second TTL, and refreshed automatically.

## Component Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                    Ring Partner API                                 │
│  POST /v1/devices/{id}/media/image/download  → JPEG Data         │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                     PartnerAPIClient                               │
│  downloadSnapshot(deviceId:token:) → Data                        │
│  Uses Bearer token authentication                                │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                    DefaultMediaService                              │
│                                                                    │
│  ┌─────────────────┐  ┌──────────────────────────────────────┐  │
│  │   NSCache        │  │  Request coalescing                  │  │
│  │  Key: String     │  │  Prevents duplicate API calls        │  │
│  │  Val: CacheEntry │  │                                      │  │
│  │  TTL: 60s        │  │                                      │  │
│  │  Max: 50MB       │  └──────────────────────────────────────┘  │
│  └─────────────────┘                                              │
│                                                                    │
│  downloadSnapshot(deviceId:) flow:                                │
│  1. Check cache → if fresh, return immediately                   │
│  2. Check in-flight → if exists, await existing task             │
│  3. Create new fetch task → store → await result                 │
│  4. Cache result with timestamp → clean up in-flight entry       │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                   DashboardViewModel                               │
│                                                                    │
│  @Published var snapshots: [String: Data] = [:]                  │
│                                                                    │
│  loadDevices() → fetchDevices → loadSnapshots(for: devices)      │
│  startBackgroundRefresh() → every 60s: refresh devices + snaps   │
│                                                                    │
│  loadSnapshots(for:) uses TaskGroup for parallel fetching        │
│  Individual failures logged but don't affect other devices        │
└────────────────────────────┬─────────────────────────────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼                              ▼
┌─────────────────────────┐  ┌─────────────────────────────────────┐
│     DeviceCardView       │  │          PlayerView                  │
│                          │  │                                      │
│  snapshotData: Data?     │  │  snapshotData: Data?                │
│  • Image as card bg      │  │  • Full-screen backdrop             │
│  • 16:9 aspect-fill      │  │  • Aspect-fill + 60% dark overlay  │
│  • Gradient overlays     │  │  • "Not yet supported" text on top  │
│  • Placeholder if nil    │  │  • Solid black fallback if nil      │
└─────────────────────────┘  └─────────────────────────────────────┘
```

## Background App Refresh

```
┌─────────────────────────────────────────────────────────────────┐
│                  BackgroundRefreshManager                         │
│                                                                   │
│  Task ID: com.ringappletv.snapshot-refresh                       │
│  Interval: 15 minutes (earliest begin date)                      │
│  Max devices: 10 per refresh                                     │
│                                                                   │
│  Flow:                                                            │
│  1. App launches → registerBackgroundTask()                      │
│  2. App appears → scheduleNextRefresh()                          │
│  3. tvOS triggers task → handleBackgroundRefresh()               │
│     a. Schedule next refresh immediately                         │
│     b. Fetch device list                                         │
│     c. Fetch snapshots for up to 10 devices (parallel)           │
│     d. Results cached in MediaService's NSCache               │
│     e. Mark task complete                                        │
│  4. User opens app → cached snapshots display instantly          │
└─────────────────────────────────────────────────────────────────┘
```

## Error Handling

| HTTP Status | Error | Behavior |
|-------------|-------|----------|
| 200 | Success | Cache JPEG data, display on card |
| 404 | `PartnerAPIError.notFound` | Show placeholder, retry next cycle |
| 429 | `PartnerAPIError.rateLimited` | Back off silently, retry next cycle |
| 401 | Token expired | `AuthService.getValidToken()` auto-refreshes |
| Network error | `PartnerAPIError.networkError` | Show placeholder, retry next cycle |

## Correctness Properties (Verified by Property-Based Tests)

| Property | Description | Test |
|----------|-------------|------|
| CP-1: Cache Freshness | Cached entry older than TTL is never returned without fresh fetch | `testCacheFreshness_staleEntryAlwaysTriggersFreshFetch` |
| CP-2: Request Coalescing | N concurrent requests for same device → exactly 1 API call | `testRequestCoalescing_concurrentRequestsMakeExactlyOneAPICall` |
| CP-3: Failure Isolation | Subset of devices failing doesn't block other devices | `testFailureIsolation_failingDevicesDoNotBlockOthers` |

## Thread Safety

- `DefaultSnapshotService` uses an internal `actor InFlightStore` to serialize access to the in-flight request dictionary
- `NSCache` is thread-safe by design (Apple documentation)
- `DashboardViewModel` is `@MainActor`-isolated — all published state updates happen on the main thread
- `BackgroundRefreshManager` uses `@unchecked Sendable` with `nonisolated(unsafe)` for service references that are set once at init

## Key Design Decisions

1. **NSCache over CacheService**: Snapshots are raw JPEG blobs. The existing `CacheService` uses JSON encoding/decoding for `Codable` models — wrapping binary data in JSON adds overhead. NSCache provides thread-safe in-memory access with automatic eviction under memory pressure.

2. **Actor for coalescing**: A Swift actor provides compile-time data race safety for the in-flight dictionary. The `getOrCreateTask(for:factory:)` method atomically checks and sets, preventing the TOCTOU race between checking if a task exists and creating one.

3. **Parallel fetching with TaskGroup**: Snapshots for all devices are fetched concurrently. Individual failures are caught and logged without propagating — this ensures one offline camera doesn't delay the entire dashboard.

4. **60-second TTL matching refresh interval**: The cache TTL equals the background refresh interval, ensuring snapshots are always fresh when displayed but never fetched more than once per cycle.
