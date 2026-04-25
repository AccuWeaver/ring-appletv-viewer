import XCTest
@testable import RingAppleTV

// MARK: - RateLimitManager Tests

final class RateLimitManagerTests: XCTestCase {

    // MARK: - canMakeRequest

    func testCanMakeRequestReturnsTrueWhenNoRequestsRecorded() {
        let manager = RateLimitManager()
        XCTAssertTrue(manager.canMakeRequest(for: "/devices"))
    }

    func testCanMakeRequestReturnsTrueUnderLimit() {
        let manager = RateLimitManager(config: .init(maxRequests: 5, windowInterval: 60))
        for _ in 0..<4 {
            manager.recordRequest(for: "/devices")
        }
        XCTAssertTrue(manager.canMakeRequest(for: "/devices"))
    }

    func testCanMakeRequestReturnsFalseAtLimit() {
        let manager = RateLimitManager(config: .init(maxRequests: 3, windowInterval: 60))
        for _ in 0..<3 {
            manager.recordRequest(for: "/devices")
        }
        XCTAssertFalse(manager.canMakeRequest(for: "/devices"))
    }

    func testCanMakeRequestReturnsFalseOverLimit() {
        let manager = RateLimitManager(config: .init(maxRequests: 2, windowInterval: 60))
        for _ in 0..<5 {
            manager.recordRequest(for: "/devices")
        }
        XCTAssertFalse(manager.canMakeRequest(for: "/devices"))
    }

    // MARK: - Endpoint isolation

    func testEndpointsAreTrackedIndependently() {
        let manager = RateLimitManager(config: .init(maxRequests: 2, windowInterval: 60))
        manager.recordRequest(for: "/devices")
        manager.recordRequest(for: "/devices")

        XCTAssertFalse(manager.canMakeRequest(for: "/devices"))
        XCTAssertTrue(manager.canMakeRequest(for: "/events"))
    }

    // MARK: - remainingRequests

    func testRemainingRequestsReturnsMaxWhenEmpty() {
        let manager = RateLimitManager(config: .init(maxRequests: 10, windowInterval: 60))
        XCTAssertEqual(manager.remainingRequests(for: "/devices"), 10)
    }

    func testRemainingRequestsDecrementsCorrectly() {
        let manager = RateLimitManager(config: .init(maxRequests: 5, windowInterval: 60))
        manager.recordRequest(for: "/devices")
        manager.recordRequest(for: "/devices")
        XCTAssertEqual(manager.remainingRequests(for: "/devices"), 3)
    }

    func testRemainingRequestsNeverNegative() {
        let manager = RateLimitManager(config: .init(maxRequests: 1, windowInterval: 60))
        manager.recordRequest(for: "/devices")
        manager.recordRequest(for: "/devices")
        XCTAssertEqual(manager.remainingRequests(for: "/devices"), 0)
    }

    // MARK: - reset

    func testResetClearsAllEndpoints() {
        let manager = RateLimitManager(config: .init(maxRequests: 1, windowInterval: 60))
        manager.recordRequest(for: "/devices")
        manager.recordRequest(for: "/events")

        XCTAssertFalse(manager.canMakeRequest(for: "/devices"))
        XCTAssertFalse(manager.canMakeRequest(for: "/events"))

        manager.reset()

        XCTAssertTrue(manager.canMakeRequest(for: "/devices"))
        XCTAssertTrue(manager.canMakeRequest(for: "/events"))
    }

    // MARK: - Thread safety

    func testConcurrentAccessDoesNotCrash() {
        let manager = RateLimitManager(config: .init(maxRequests: 100, windowInterval: 60))
        let group = DispatchGroup()

        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                manager.recordRequest(for: "/endpoint\(i % 5)")
                _ = manager.canMakeRequest(for: "/endpoint\(i % 5)")
                _ = manager.remainingRequests(for: "/endpoint\(i % 5)")
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
    }

    // MARK: - Default config

    func testDefaultConfigAllowsTenRequestsPerMinute() {
        let manager = RateLimitManager()
        for _ in 0..<10 {
            manager.recordRequest(for: "/test")
        }
        XCTAssertFalse(manager.canMakeRequest(for: "/test"))
    }
}

// MARK: - RetryStrategy Tests

final class RetryStrategyTests: XCTestCase {

    // MARK: - Backoff calculation

    func testDelayForAttemptZeroIsOneSecond() {
        XCTAssertEqual(RetryStrategy.delay(for: 0), 1.0)
    }

    func testDelayForAttemptOneIsTwoSeconds() {
        XCTAssertEqual(RetryStrategy.delay(for: 1), 2.0)
    }

    func testDelayForAttemptTwoIsFourSeconds() {
        XCTAssertEqual(RetryStrategy.delay(for: 2), 4.0)
    }

    func testDelayForAttemptThreeIsEightSeconds() {
        XCTAssertEqual(RetryStrategy.delay(for: 3), 8.0)
    }

    func testDelayGrowsExponentially() {
        for attempt in 0..<5 {
            let expected = pow(2.0, Double(attempt))
            XCTAssertEqual(RetryStrategy.delay(for: attempt), expected, accuracy: 0.001)
        }
    }

    // MARK: - Max delay cap

    func testDelayCappedAtSixtySeconds() {
        XCTAssertEqual(RetryStrategy.delay(for: 6), 60.0)  // 2^6 = 64 → capped at 60
    }

    func testDelayForVeryLargeAttemptIsCapped() {
        XCTAssertEqual(RetryStrategy.delay(for: 100), 60.0)
    }

    func testDelayAtBoundary() {
        // 2^5 = 32, still under cap
        XCTAssertEqual(RetryStrategy.delay(for: 5), 32.0)
    }

    // MARK: - shouldRetry — retryable errors

    func testShouldRetryNetworkError() {
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .networkError("timeout"), attempt: 0))
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .networkError("timeout"), attempt: 1))
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .networkError("timeout"), attempt: 2))
    }

    func testShouldRetryServerError() {
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .serverError(500), attempt: 0))
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .serverError(503), attempt: 1))
    }

    func testShouldRetryRateLimited() {
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .rateLimited, attempt: 0))
        XCTAssertTrue(RetryStrategy.shouldRetry(error: .rateLimited, attempt: 2))
    }

    // MARK: - shouldRetry — non-retryable errors

    func testShouldNotRetryInvalidCredentials() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .invalidCredentials, attempt: 0))
    }

    func testShouldNotRetryTwoFactorRequired() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .twoFactorRequired, attempt: 0))
    }

    func testShouldNotRetryTwoFactorInvalid() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .twoFactorInvalid, attempt: 0))
    }

    func testShouldNotRetryDecodingError() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .decodingError("bad json"), attempt: 0))
    }

    func testShouldNotRetryTokenExpired() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .tokenExpired, attempt: 0))
    }

    func testShouldNotRetryTokenRefreshFailed() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .tokenRefreshFailed, attempt: 0))
    }

    func testShouldNotRetryDeviceOffline() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .deviceOffline, attempt: 0))
    }

    func testShouldNotRetryStreamUnavailable() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .streamUnavailable, attempt: 0))
    }

    func testShouldNotRetryUnknown() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .unknown("???"), attempt: 0))
    }

    // MARK: - shouldRetry — max retries exhausted

    func testShouldNotRetryWhenMaxRetriesExhausted() {
        // Max retries is 3, so attempt 3 (the 4th try) should not retry
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .networkError("timeout"), attempt: 3))
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .serverError(500), attempt: 3))
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .rateLimited, attempt: 3))
    }

    func testShouldNotRetryBeyondMaxRetries() {
        XCTAssertFalse(RetryStrategy.shouldRetry(error: .networkError("timeout"), attempt: 10))
    }

    // MARK: - Constants

    func testMaxRetriesIsThree() {
        XCTAssertEqual(RetryStrategy.maxRetries, 3)
    }

    func testMaxDelayIsSixtySeconds() {
        XCTAssertEqual(RetryStrategy.maxDelay, 60.0)
    }
}
