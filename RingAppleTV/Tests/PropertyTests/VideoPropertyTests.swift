import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Generators

/// Generates a `StreamSession` with random `createdAt` offsets and `maxDuration`.
private nonisolated(unsafe) let streamSessionGen: Gen<StreamSession> = Gen<StreamSession>.compose { c in
    let offsetSeconds = c.generate(using: Int.arbitrary.suchThat { $0 >= 0 && $0 < 7200 })
    let powerSource: PowerSource = c.generate(using: Bool.arbitrary) ? .battery : .line

    return StreamSession(
        deviceId: String(c.generate(using: Int.arbitrary.suchThat { $0 > 0 })),
        sessionURL: URL(string: "https://api.amazonvision.com/v1/sessions/\(UUID().uuidString)")!,
        powerSource: powerSource,
        createdAt: Date().addingTimeInterval(-Double(offsetSeconds))
    )
}

extension StreamSession: Arbitrary {
    public static var arbitrary: Gen<StreamSession> {
        streamSessionGen
    }
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
            <- forAll(streamSessionGen) { session -> Bool in
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
