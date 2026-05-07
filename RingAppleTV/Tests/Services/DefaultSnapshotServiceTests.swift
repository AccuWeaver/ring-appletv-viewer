import XCTest
@testable import RingAppleTV

final class DefaultSnapshotServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        authService: MockAuthService = {
            let auth = MockAuthService()
            auth.getValidTokenResult = .success(MockData.validToken)
            return auth
        }(),
        apiClient: MockRingAPIClient = MockRingAPIClient(),
        cacheTTL: TimeInterval = 60
    ) -> (DefaultSnapshotService, MockAuthService, MockRingAPIClient) {
        let sut = DefaultSnapshotService(authService: authService, apiClient: apiClient, cacheTTL: cacheTTL)
        return (sut, authService, apiClient)
    }

    // MARK: - 8.4 Cache hit returns data without API call

    func testGetSnapshot_cacheHit_returnsDataWithoutAPICall() async throws {
        let (sut, _, apiClient) = makeSUT()
        apiClient.fetchSnapshotResult = .success(MockData.sampleJPEGData)

        // First call — cache miss, triggers API
        let first = try await sut.getSnapshot(for: 1001)
        XCTAssertEqual(first, MockData.sampleJPEGData)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1)

        // Second call — cache hit, no additional API call
        let second = try await sut.getSnapshot(for: 1001)
        XCTAssertEqual(second, MockData.sampleJPEGData)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1, "Cache hit should not trigger another API call")
    }

    // MARK: - 8.5 Cache miss triggers API call and caches result

    func testGetSnapshot_cacheMiss_triggersAPICallAndCachesResult() async throws {
        let (sut, auth, apiClient) = makeSUT()
        apiClient.fetchSnapshotResult = .success(MockData.sampleJPEGData)

        let data = try await sut.getSnapshot(for: 2002)

        XCTAssertEqual(data, MockData.sampleJPEGData)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.first?.deviceId, 2002)
        XCTAssertEqual(auth.getValidTokenCalls, 1, "Should request a valid token")

        // Verify it's cached — second call should not hit API
        let cached = try await sut.getSnapshot(for: 2002)
        XCTAssertEqual(cached, MockData.sampleJPEGData)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1)
    }

    // MARK: - 8.6 Stale cache triggers fresh fetch

    func testGetSnapshot_staleCache_triggersFreshFetch() async throws {
        let (sut, _, apiClient) = makeSUT(cacheTTL: 0.1) // 100ms TTL
        apiClient.fetchSnapshotResult = .success(MockData.sampleJPEGData)

        // First call — populates cache
        _ = try await sut.getSnapshot(for: 1001)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1)

        // Wait for cache to expire
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Second call — stale cache, should trigger fresh fetch
        _ = try await sut.getSnapshot(for: 1001)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 2, "Stale cache should trigger a fresh API call")
    }

    // MARK: - 8.7 Concurrent requests coalesce into one API call

    func testGetSnapshot_concurrentRequests_coalesceIntoOneAPICall() async throws {
        let (sut, _, apiClient) = makeSUT()
        apiClient.fetchSnapshotResult = .success(MockData.sampleJPEGData)

        // Launch multiple concurrent requests for the same device
        async let r1 = sut.getSnapshot(for: 1001)
        async let r2 = sut.getSnapshot(for: 1001)
        async let r3 = sut.getSnapshot(for: 1001)

        let results = try await [r1, r2, r3]

        // All should return the same data
        for result in results {
            XCTAssertEqual(result, MockData.sampleJPEGData)
        }

        // Only 1 API call should have been made (coalesced)
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1, "Concurrent requests should coalesce into a single API call")
    }

    // MARK: - 8.8 429 response doesn't trigger immediate retry

    func testGetSnapshot_rateLimited_throwsWithoutRetry() async throws {
        let (sut, _, apiClient) = makeSUT()
        apiClient.fetchSnapshotResult = .failure(RingAPIError.rateLimited)

        do {
            _ = try await sut.getSnapshot(for: 1001)
            XCTFail("Expected rateLimited error to be thrown")
        } catch let error as RingAPIError {
            XCTAssertEqual(error, .rateLimited)
        }

        // Should have made exactly 1 API call — no retry
        XCTAssertEqual(apiClient.fetchSnapshotCalls.count, 1, "429 should not trigger an immediate retry")
    }
}
