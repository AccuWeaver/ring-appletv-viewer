import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Per-Device Configurable Mock API Client

/// A mock API client that can be configured to fail for specific device IDs.
/// Used by CP-3 (Failure Isolation) property tests.
private final class PerDeviceAPIClient: RingAPIClient, @unchecked Sendable {
    /// Device IDs that should fail when fetched.
    var failingDeviceIds: Set<Int> = []
    /// Tracks how many times fetchSnapshot was called per device.
    var fetchSnapshotCallCounts: [Int: Int] = [:]
    private let lock = NSLock()

    func fetchSnapshot(deviceId: Int, token: String) async throws -> Data {
        let shouldFail: Bool = lock.withLock {
            fetchSnapshotCallCounts[deviceId, default: 0] += 1
            return failingDeviceIds.contains(deviceId)
        }

        if shouldFail {
            throw RingAPIError.noSnapshotAvailable
        }
        // Return unique data per device so we can verify correct routing
        return Data("snapshot-\(deviceId)".utf8)
    }

    // MARK: - Unused protocol stubs

    func authenticate(email: String, password: String) async throws -> AuthTokenResponse {
        fatalError("Not used in property tests")
    }
    func authenticate(email: String, password: String, twoFactorCode: String) async throws -> AuthTokenResponse {
        fatalError("Not used in property tests")
    }
    func refreshToken(_ refreshToken: String) async throws -> AuthTokenResponse {
        fatalError("Not used in property tests")
    }
    func fetchDevices(token: String) async throws -> [RingDeviceResponse] {
        fatalError("Not used in property tests")
    }
    func requestLiveStream(deviceId: Int, token: String) async throws -> StreamSessionResponse {
        fatalError("Not used in property tests")
    }
    func fetchEvents(deviceId: Int, token: String, limit: Int) async throws -> [RingEventResponse] {
        fatalError("Not used in property tests")
    }
    func fetchEventVideoURL(eventId: Int, token: String) async throws -> URL {
        fatalError("Not used in property tests")
    }
    func requestSnapshot(deviceId: Int, token: String) async throws {
        fatalError("Not used in property tests")
    }
}

// MARK: - Counting Mock API Client

/// A mock API client that counts fetchSnapshot calls with thread-safe tracking.
/// Used by CP-1 (Cache Freshness) and CP-2 (Request Coalescing) property tests.
private final class CountingAPIClient: RingAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchSnapshotCallCount: Int = 0

    var fetchSnapshotCallCount: Int {
        lock.withLock { _fetchSnapshotCallCount }
    }

    func fetchSnapshot(deviceId: Int, token: String) async throws -> Data {
        lock.withLock { _fetchSnapshotCallCount += 1 }
        return MockData.sampleJPEGData
    }

    // MARK: - Unused protocol stubs

    func authenticate(email: String, password: String) async throws -> AuthTokenResponse {
        fatalError("Not used in property tests")
    }
    func authenticate(email: String, password: String, twoFactorCode: String) async throws -> AuthTokenResponse {
        fatalError("Not used in property tests")
    }
    func refreshToken(_ refreshToken: String) async throws -> AuthTokenResponse {
        fatalError("Not used in property tests")
    }
    func fetchDevices(token: String) async throws -> [RingDeviceResponse] {
        fatalError("Not used in property tests")
    }
    func requestLiveStream(deviceId: Int, token: String) async throws -> StreamSessionResponse {
        fatalError("Not used in property tests")
    }
    func fetchEvents(deviceId: Int, token: String, limit: Int) async throws -> [RingEventResponse] {
        fatalError("Not used in property tests")
    }
    func fetchEventVideoURL(eventId: Int, token: String) async throws -> URL {
        fatalError("Not used in property tests")
    }
    func requestSnapshot(deviceId: Int, token: String) async throws {
        fatalError("Not used in property tests")
    }
}

// MARK: - Failure Isolation Scenario

/// Wraps the scenario data for CP-3 property tests in a type that can conform to Arbitrary.
private struct FailureScenario {
    let allIds: [Int]
    let failIds: [Int]
}

extension FailureScenario: Arbitrary {
    static var arbitrary: Gen<FailureScenario> {
        Gen<Int>.fromElements(in: 2...15).flatMap { totalCount in
            Gen<UInt32>.fromElements(in: 0...UInt32(1 << min(totalCount, 20) - 1)).map { mask in
                let allIds = Array(1...totalCount)
                var failIds: [Int] = []
                for i in 0..<totalCount {
                    if mask & (1 << i) != 0 {
                        failIds.append(allIds[i])
                    }
                }
                // Ensure at least one device succeeds so the test is meaningful
                let failSet = Set(failIds)
                let successIds = allIds.filter { !failSet.contains($0) }
                if successIds.isEmpty {
                    return FailureScenario(allIds: allIds, failIds: Array(failIds.dropLast()))
                }
                return FailureScenario(allIds: allIds, failIds: failIds)
            }
        }
    }
}

// MARK: - Property Tests

/// Property-based tests for snapshot service correctness properties.
///
/// **Validates: Requirements CP-1, CP-2, CP-3**
final class SnapshotPropertyTests: XCTestCase {

    private func makeAuthService() -> MockAuthService {
        let auth = MockAuthService()
        auth.getValidTokenResult = .success(MockData.validToken)
        return auth
    }

    // MARK: - CP-1: Cache Freshness

    /// **Validates: Requirements CP-1**
    ///
    /// Property: For any TTL value, after waiting longer than the TTL,
    /// a second getSnapshot call must trigger a fresh API fetch (not return stale cache).
    func testCacheFreshness_staleEntryAlwaysTriggersFreshFetch() {
        // Generate TTL values between 0.02s and 0.10s to keep tests fast
        let ttlGen = Double.arbitrary
            .suchThat { $0 > 0 }
            .map { abs($0).truncatingRemainder(dividingBy: 0.08) + 0.02 }

        property("CP-1: stale cache always triggers fresh fetch")
            <- forAll(ttlGen) { (ttl: Double) in
                let apiClient = CountingAPIClient()
                let sut = DefaultSnapshotService(
                    authService: self.makeAuthService(),
                    apiClient: apiClient,
                    cacheTTL: ttl
                )

                let expectation = XCTestExpectation(description: "CP-1 iteration")

                Task {
                    // First fetch — populates cache (1 API call)
                    _ = try await sut.getSnapshot(for: 42)
                    let callsAfterFirst = apiClient.fetchSnapshotCallCount

                    // Wait longer than TTL so cache becomes stale
                    try await Task.sleep(nanoseconds: UInt64((ttl + 0.02) * 1_000_000_000))

                    // Second fetch — cache is stale, must trigger fresh fetch
                    _ = try await sut.getSnapshot(for: 42)
                    let callsAfterSecond = apiClient.fetchSnapshotCallCount

                    // Verify a new API call was made
                    XCTAssertEqual(callsAfterFirst, 1, "First fetch should make exactly 1 API call")
                    XCTAssertGreaterThan(callsAfterSecond, callsAfterFirst,
                        "Stale cache (TTL=\(ttl)s) must trigger a fresh API call")
                    expectation.fulfill()
                }

                let result = XCTWaiter.wait(for: [expectation], timeout: 5.0)
                return result == .completed
            }
    }

    // MARK: - CP-2: Request Coalescing

    /// **Validates: Requirements CP-2**
    ///
    /// Property: For any N concurrent requests (2–20) for the same device,
    /// exactly 1 API call is made.
    func testRequestCoalescing_concurrentRequestsMakeExactlyOneAPICall() {
        // Generate N between 2 and 20
        let nGen = Gen<Int>.fromElements(in: 2...20)

        property("CP-2: N concurrent requests produce exactly 1 API call")
            <- forAll(nGen) { (n: Int) in
                let apiClient = CountingAPIClient()
                let sut = DefaultSnapshotService(
                    authService: self.makeAuthService(),
                    apiClient: apiClient,
                    cacheTTL: 60
                )

                let expectation = XCTestExpectation(description: "CP-2 iteration")

                Task {
                    // Launch N concurrent requests for the same device
                    let results: [Data] = try await withThrowingTaskGroup(of: Data.self) { group in
                        for _ in 0..<n {
                            group.addTask {
                                try await sut.getSnapshot(for: 99)
                            }
                        }
                        var collected: [Data] = []
                        for try await data in group {
                            collected.append(data)
                        }
                        return collected
                    }

                    // All N callers should get a result
                    XCTAssertEqual(results.count, n, "All \(n) callers should receive data")

                    // All results should be identical
                    let allSame = results.allSatisfy { $0 == results.first }
                    XCTAssertTrue(allSame, "All callers should receive the same snapshot data")

                    // Exactly 1 API call should have been made
                    XCTAssertEqual(apiClient.fetchSnapshotCallCount, 1,
                        "N=\(n) concurrent requests should coalesce into exactly 1 API call")
                    expectation.fulfill()
                }

                let result = XCTWaiter.wait(for: [expectation], timeout: 5.0)
                return result == .completed
            }
    }

    // MARK: - CP-3: Failure Isolation

    /// **Validates: Requirements CP-3**
    ///
    /// Property: For any subset of devices that fail, all non-failing devices
    /// still receive their snapshots successfully.
    func testFailureIsolation_failingDevicesDoNotBlockOthers() {
        property("CP-3: failing devices do not block other devices")
            <- forAll { (scenario: FailureScenario) in
                let apiClient = PerDeviceAPIClient()
                apiClient.failingDeviceIds = Set(scenario.failIds)
                let sut = DefaultSnapshotService(
                    authService: self.makeAuthService(),
                    apiClient: apiClient,
                    cacheTTL: 60
                )

                let failSet = Set(scenario.failIds)
                let expectation = XCTestExpectation(description: "CP-3 iteration")

                Task {
                    // Fetch snapshots for all devices in parallel
                    let results: [(id: Int, data: Data?, error: Error?)] = await withTaskGroup(
                        of: (Int, Data?, Error?).self
                    ) { group in
                        for deviceId in scenario.allIds {
                            group.addTask {
                                do {
                                    let data = try await sut.getSnapshot(for: deviceId)
                                    return (deviceId, data, nil)
                                } catch {
                                    return (deviceId, nil, error)
                                }
                            }
                        }
                        var collected: [(Int, Data?, Error?)] = []
                        for await result in group {
                            collected.append(result)
                        }
                        return collected
                    }

                    // Verify: every non-failing device got its snapshot
                    for result in results {
                        if !failSet.contains(result.id) {
                            XCTAssertNotNil(result.data,
                                "Device \(result.id) should succeed (failSet=\(scenario.failIds))")
                            XCTAssertNil(result.error,
                                "Device \(result.id) should not have an error")
                        }
                    }

                    // Verify: failing devices did fail
                    for result in results where failSet.contains(result.id) {
                        XCTAssertNil(result.data,
                            "Device \(result.id) should have failed")
                        XCTAssertNotNil(result.error,
                            "Device \(result.id) should have an error")
                    }

                    expectation.fulfill()
                }

                let result = XCTWaiter.wait(for: [expectation], timeout: 10.0)
                return result == .completed
            }
    }
}
