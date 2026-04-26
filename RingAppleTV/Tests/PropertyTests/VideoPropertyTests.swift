import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Generators

/// Generates a `StreamSession` with random `createdAt` offsets and `maxDuration`.
private let streamSessionGen: Gen<StreamSession> = Gen<StreamSession>.compose { c in
    // createdAt can be in the past (up to 2 hours ago) or recent
    let offsetSeconds = c.generate(using: Int.arbitrary.suchThat { $0 >= 0 && $0 < 7200 })
    let maxDuration = c.generate(using: Int.arbitrary.suchThat { $0 >= 0 && $0 < 3600 })

    return StreamSession(
        deviceId: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
        sipServerIp: "52.12.182.65",
        sipServerPort: 15064,
        sipSessionId: "test-session",
        protocol_: "sip",
        createdAt: Date().addingTimeInterval(-Double(offsetSeconds)),
        maxDuration: TimeInterval(maxDuration)
    )
}

// MARK: - Property Tests

/// Property-based tests for stream session validity.
///
/// **Property 6**: `isValid` is `true` iff `remainingTime > 0`,
/// and `remainingTime` is always `≥ 0` and `≤ maxDuration`.
final class VideoPropertyTests: XCTestCase {

    /// Feature: AppleTVRing, Property 6: Stream session validity consistent with elapsed time
    func testStreamSessionValidityConsistentWithElapsedTime() {
        property("Feature: AppleTVRing, Property 6: Stream session validity consistent with elapsed time")
            <- forAll(streamSessionGen) { (session: StreamSession) in
                let remaining = session.remainingTime
                let valid = session.isValid

                // remainingTime must be >= 0
                guard remaining >= 0 else { return false }

                // remainingTime must be <= maxDuration
                guard remaining <= session.maxDuration else { return false }

                // isValid iff remainingTime > 0
                guard valid == (remaining > 0) else { return false }

                return true
            }
    }
}
