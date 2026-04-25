import XCTest
import SwiftCheck
@testable import RingAppleTV

/// Property-based tests for `RetryStrategy`.
///
/// - Property A: Delay grows monotonically (delay(n+1) >= delay(n)).
/// - Property B: Delay never exceeds 60 seconds.
///
/// Uses SwiftCheck with 50 iterations per property.
final class RetryPropertyTests: XCTestCase {

    // MARK: - Property A: Exponential growth (monotonically non-decreasing)

    /// Feature: AppleTVRing, Retry Property A: delay grows exponentially
    func testDelayGrowsMonotonically() {
        // Generate attempt values in [0, 20] to cover both below and above the cap.
        let attemptGen = Int.arbitrary.suchThat { $0 >= 0 && $0 < 20 }

        property("Feature: AppleTVRing, Retry Property A: delay(n+1) >= delay(n)")
            <- forAll(attemptGen) { (attempt: Int) in
                let current = RetryStrategy.delay(for: attempt)
                let next = RetryStrategy.delay(for: attempt + 1)
                return next >= current
            }
    }

    // MARK: - Property B: Delay never exceeds 60 seconds

    /// Feature: AppleTVRing, Retry Property B: delay never exceeds max
    func testDelayNeverExceedsMaxDelay() {
        // Generate attempt values in [0, 100] to stress the cap.
        let attemptGen = Int.arbitrary.suchThat { $0 >= 0 && $0 <= 100 }

        property("Feature: AppleTVRing, Retry Property B: delay <= 60s")
            <- forAll(attemptGen) { (attempt: Int) in
                let d = RetryStrategy.delay(for: attempt)
                return d <= RetryStrategy.maxDelay
            }
    }
}
