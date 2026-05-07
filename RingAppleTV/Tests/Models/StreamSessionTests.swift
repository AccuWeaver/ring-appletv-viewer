import XCTest
@testable import RingAppleTV

final class StreamSessionTests: XCTestCase {

    // MARK: - isValid

    func testIsValidReturnsTrueForRecentSession() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://api.amazonvision.com/v1/sessions/test")!,
            powerSource: .line,
            createdAt: Date()
        )
        XCTAssertTrue(session.isValid)
    }

    func testIsValidReturnsFalseForExpiredSession() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://api.amazonvision.com/v1/sessions/test")!,
            powerSource: .line,
            createdAt: Date.distantPast
        )
        XCTAssertFalse(session.isValid)
    }

    // MARK: - maxDuration from PowerSource

    func testMaxDurationBattery() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://example.com/session")!,
            powerSource: .battery,
            createdAt: Date()
        )
        XCTAssertEqual(session.maxDuration, 30)
    }

    func testMaxDurationLine() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://example.com/session")!,
            powerSource: .line,
            createdAt: Date()
        )
        XCTAssertEqual(session.maxDuration, 60)
    }

    // MARK: - remainingTime

    func testRemainingTimeIsNonNegativeForExpiredSession() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://example.com/session")!,
            powerSource: .line,
            createdAt: Date.distantPast
        )
        XCTAssertEqual(session.remainingTime, 0)
    }

    func testRemainingTimeIsPositiveForRecentSession() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://example.com/session")!,
            powerSource: .line,
            createdAt: Date()
        )
        XCTAssertGreaterThan(session.remainingTime, 0)
        XCTAssertLessThanOrEqual(session.remainingTime, 60)
    }

    func testRemainingTimeEqualsMaxDurationWhenJustCreated() {
        let session = StreamSession(
            deviceId: "1",
            sessionURL: URL(string: "https://example.com/session")!,
            powerSource: .line,
            createdAt: Date()
        )
        XCTAssertEqual(session.remainingTime, 60, accuracy: 1.0)
    }

    // MARK: - Equatable

    func testEquatableForEqualSessions() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://example.com/session")!
        let a = StreamSession(deviceId: "1", sessionURL: url, powerSource: .line, createdAt: date)
        let b = StreamSession(deviceId: "1", sessionURL: url, powerSource: .line, createdAt: date)
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentDeviceId() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://example.com/session")!
        let a = StreamSession(deviceId: "1", sessionURL: url, powerSource: .line, createdAt: date)
        let b = StreamSession(deviceId: "2", sessionURL: url, powerSource: .line, createdAt: date)
        XCTAssertNotEqual(a, b)
    }

    func testEquatableForDifferentPowerSource() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://example.com/session")!
        let a = StreamSession(deviceId: "1", sessionURL: url, powerSource: .battery, createdAt: date)
        let b = StreamSession(deviceId: "1", sessionURL: url, powerSource: .line, createdAt: date)
        XCTAssertNotEqual(a, b)
    }
}
