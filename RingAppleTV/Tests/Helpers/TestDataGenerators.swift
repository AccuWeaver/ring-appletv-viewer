import Foundation
import SwiftCheck
@testable import RingAppleTV

/// Reusable SwiftCheck generators for property-based tests.
enum TestDataGenerators {

    // MARK: - Auth Token Generators

    /// Generates a random valid (non-expired) `AuthToken`.
    nonisolated(unsafe) static let validToken: Gen<AuthToken> = Gen<AuthToken>.compose { c in
        let futureOffset = c.generate(using: Int.arbitrary.suchThat { $0 > 300 && $0 < 100_000 })
        return AuthToken(
            accessToken: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            refreshToken: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            expiresAt: Date().addingTimeInterval(Double(futureOffset)),
            scope: c.generate(using: String?.arbitrary),
            tokenType: "Bearer"
        )
    }

    /// Generates a random expired `AuthToken`.
    nonisolated(unsafe) static let expiredToken: Gen<AuthToken> = Gen<AuthToken>.compose { c in
        let pastOffset = c.generate(using: Int.arbitrary.suchThat { $0 > 60 && $0 < 1_000_000 })
        return AuthToken(
            accessToken: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            refreshToken: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            expiresAt: Date().addingTimeInterval(-Double(pastOffset)),
            scope: c.generate(using: String?.arbitrary),
            tokenType: "Bearer"
        )
    }

    /// Generates any random `AuthToken` (may be valid or expired).
    nonisolated(unsafe) static let anyToken: Gen<AuthToken> = Gen<AuthToken>.compose { c in
        let offset = c.generate(using: Int.arbitrary.suchThat { abs($0) > 0 && abs($0) < 1_000_000 })
        return AuthToken(
            accessToken: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            refreshToken: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            expiresAt: Date().addingTimeInterval(Double(offset)),
            scope: c.generate(using: String?.arbitrary),
            tokenType: "Bearer"
        )
    }

    // MARK: - Device Generators

    /// Generates a random `RingDevice.DeviceType`.
    nonisolated(unsafe) static let deviceType: Gen<RingDevice.DeviceType> = Gen<RingDevice.DeviceType>.fromElements(of:
        RingDevice.DeviceType.allCases
    )

    /// Generates a random `RingDevice`.
    nonisolated(unsafe) static let device: Gen<RingDevice> = Gen<RingDevice>.compose { c in
        RingDevice(
            id: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
            description: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            deviceType: c.generate(using: deviceType),
            firmwareVersion: c.generate(using: String?.arbitrary),
            address: c.generate(using: String?.arbitrary),
            batteryLife: c.generate(using: Int?.arbitrary),
            features: nil,
            isOnline: c.generate(using: Bool.arbitrary)
        )
    }

    /// Generates a random non-empty array of `RingDevice` (1–20 items).
    nonisolated(unsafe) static let deviceList: Gen<[RingDevice]> = device
        .proliferate(withSize: 20)
        .suchThat { !$0.isEmpty }

    // MARK: - Event Generators

    /// Generates a random `RingEvent.EventType`.
    nonisolated(unsafe) static let eventType: Gen<RingEvent.EventType> = Gen<RingEvent.EventType>.fromElements(of: [
        .motion, .ding, .onDemand
    ])

    /// Generates a random `RingEvent`.
    nonisolated(unsafe) static let event: Gen<RingEvent> = Gen<RingEvent>.compose { c in
        let hoursAgo = c.generate(using: Int.arbitrary.suchThat { $0 > 0 && $0 < 10_000 })
        return RingEvent(
            id: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
            deviceId: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
            deviceName: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
            eventType: c.generate(using: eventType),
            createdAt: Date().addingTimeInterval(-Double(hoursAgo)),
            duration: c.generate(using: Double?.arbitrary),
            thumbnailURL: nil,
            videoAvailable: c.generate(using: Bool.arbitrary)
        )
    }

    /// Generates a random array of `RingEvent` (0–100 items).
    nonisolated(unsafe) static let eventList: Gen<[RingEvent]> = event.proliferate(withSize: 100)

    // MARK: - Stream Session Generators

    /// Generates a random `StreamSession` with varying creation times and durations.
    nonisolated(unsafe) static let streamSession: Gen<StreamSession> = Gen<StreamSession>.compose { c in
        let secondsAgo = c.generate(using: Int.arbitrary.suchThat { $0 >= 0 && $0 < 1200 })
        let maxDuration = c.generate(using: Int.arbitrary.suchThat { $0 > 0 && $0 <= 1200 })
        return StreamSession(
            deviceId: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date().addingTimeInterval(-Double(secondsAgo)),
            maxDuration: Double(maxDuration)
        )
    }

    // MARK: - Filter / Sort Generators

    /// Generates a random `DeviceFilter`.
    nonisolated(unsafe) static let deviceFilter: Gen<DeviceFilter> = Gen<Int>.fromElements(in: 0...3).flatMap { choice in
        switch choice {
        case 0:
            return Gen.pure(.all)
        case 1:
            return String.arbitrary.suchThat { !$0.isEmpty }.map { DeviceFilter.name($0) }
        case 2:
            return deviceType.map { DeviceFilter.type($0) }
        default:
            return Bool.arbitrary.map { $0 ? DeviceFilter.status(.online) : DeviceFilter.status(.offline) }
        }
    }

    /// Generates a random `DeviceSort`.
    nonisolated(unsafe) static let deviceSort: Gen<DeviceSort> = Gen<DeviceSort>.fromElements(of: [
        .nameAscending, .nameDescending, .type, .status
    ])
}
