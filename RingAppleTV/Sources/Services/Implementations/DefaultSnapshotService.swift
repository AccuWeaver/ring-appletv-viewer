import Foundation
import os

/// Production implementation of `SnapshotService` that fetches, caches, and coalesces
/// snapshot requests for Ring camera devices.
final class DefaultSnapshotService: SnapshotService, @unchecked Sendable {

    // MARK: - Cache Entry

    /// Wrapper to store snapshot data and fetch timestamp in NSCache.
    private class CacheEntry: NSObject {
        let data: NSData
        let fetchedAt: Date
        init(data: NSData, fetchedAt: Date) {
            self.data = data
            self.fetchedAt = fetchedAt
            super.init()
        }
    }

    // MARK: - Dependencies

    nonisolated(unsafe) private let authService: AuthService
    nonisolated(unsafe) private let apiClient: RingAPIClient

    // MARK: - Cache

    private let cache = NSCache<NSNumber, CacheEntry>()
    private let cacheTTL: TimeInterval

    // MARK: - Request Coalescing (actor-isolated)

    /// Actor that serialises access to the in-flight request dictionary,
    /// preventing data races when multiple callers request the same device concurrently.
    private actor InFlightStore {
        var requests: [Int: Task<Data, Error>] = [:]

        /// Returns the existing in-flight task for a device, or creates and stores a new one.
        /// This ensures atomic check-and-set to prevent duplicate tasks.
        func getOrCreateTask(
            for deviceId: Int,
            factory: sending @escaping () async throws -> Data
        ) -> Task<Data, Error> {
            if let existing = requests[deviceId] {
                return existing
            }
            let newTask = Task<Data, Error> {
                try await factory()
            }
            requests[deviceId] = newTask
            return newTask
        }

        func remove(_ deviceId: Int) {
            requests[deviceId] = nil
        }
    }

    private let inFlightStore = InFlightStore()

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.ringappletv", category: "SnapshotService")

    // MARK: - Init

    init(authService: AuthService, apiClient: RingAPIClient, cacheTTL: TimeInterval = 60) {
        self.authService = authService
        self.apiClient = apiClient
        self.cacheTTL = cacheTTL

        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    // MARK: - SnapshotService

    func getSnapshot(for deviceId: Int) async throws -> Data {
        // 1. Check cache for a fresh entry
        let key = NSNumber(value: deviceId)
        if let entry = cache.object(forKey: key),
           Date().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            logger.debug("Cache hit for device \(deviceId)")
            return entry.data as Data
        }

        // 2. Atomically get or create an in-flight task for this device
        let authService = self.authService
        let apiClient = self.apiClient
        let cache = self.cache
        let logger = self.logger
        let cacheTTL = self.cacheTTL

        let task = await inFlightStore.getOrCreateTask(for: deviceId) {
            let token = try await authService.getValidToken()
            let data = try await apiClient.fetchSnapshot(deviceId: deviceId, token: token.accessToken)

            // Cache the result
            let entry = CacheEntry(data: data as NSData, fetchedAt: Date())
            cache.setObject(entry, forKey: key, cost: data.count)
            logger.debug("Cached snapshot for device \(deviceId) (\(data.count) bytes)")

            return data
        }

        defer {
            Task { [inFlightStore] in
                await inFlightStore.remove(deviceId)
            }
        }

        return try await task.value
    }

    func requestNewSnapshot(for deviceId: Int) async throws {
        let token = try await authService.getValidToken()
        try await apiClient.requestSnapshot(deviceId: deviceId, token: token.accessToken)
    }

    func clearCache() {
        cache.removeAllObjects()
        logger.debug("Snapshot cache cleared")
    }
}
