import Foundation
@testable import RingAppleTV

/// Mock `SnapshotService` with configurable return values and call tracking.
final class MockSnapshotService: SnapshotService, @unchecked Sendable {

    // MARK: - getSnapshot

    var getSnapshotResult: Result<Data, Error> = .failure(RingAPIError.noSnapshotAvailable)
    var getSnapshotCalls: [Int] = []

    func getSnapshot(for deviceId: Int) async throws -> Data {
        getSnapshotCalls.append(deviceId)
        return try getSnapshotResult.get()
    }

    // MARK: - requestNewSnapshot

    var requestNewSnapshotResult: Result<Void, Error> = .success(())
    var requestNewSnapshotCalls: [Int] = []

    func requestNewSnapshot(for deviceId: Int) async throws {
        requestNewSnapshotCalls.append(deviceId)
        try requestNewSnapshotResult.get()
    }

    // MARK: - clearCache

    var clearCacheCalls = 0

    func clearCache() {
        clearCacheCalls += 1
    }
}
