import Foundation

/// Manages snapshot retrieval, caching, and refresh for Ring camera devices.
protocol SnapshotService: Sendable {
    /// Fetch the latest snapshot for a device. Returns cached data if fresh (< 60s).
    func getSnapshot(for deviceId: Int) async throws -> Data

    /// Request Ring to capture a new snapshot. Subject to rate limiting.
    func requestNewSnapshot(for deviceId: Int) async throws

    /// Clear all cached snapshots.
    func clearCache()
}
