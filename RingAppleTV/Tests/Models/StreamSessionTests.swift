import XCTest
@testable import RingAppleTV

final class StreamSessionTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let session = StreamSession(
            deviceId: 42,
            hlsURL: URL(string: "https://ring.com/live/42.m3u8")!,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000),
            maxDuration: 600
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(StreamSession.self, from: data)

        XCTAssertEqual(decoded, session)
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://example.com/stream.m3u8")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            maxDuration: 300
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(StreamSession.self, from: data)

        XCTAssertEqual(decoded.deviceId, 1)
        XCTAssertEqual(decoded.hlsURL, URL(string: "https://example.com/stream.m3u8")!)
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(decoded.maxDuration, 300)
    }

    // MARK: - isValid

    func testIsValidReturnsTrueForRecentSession() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date(),
            maxDuration: 600
        )
        XCTAssertTrue(session.isValid)
    }

    func testIsValidReturnsFalseForExpiredSession() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date.distantPast,
            maxDuration: 600
        )
        XCTAssertFalse(session.isValid)
    }

    func testIsValidReturnsFalseWhenMaxDurationIsZero() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date(),
            maxDuration: 0
        )
        XCTAssertFalse(session.isValid)
    }

    // MARK: - remainingTime

    func testRemainingTimeIsNonNegativeForExpiredSession() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date.distantPast,
            maxDuration: 600
        )
        XCTAssertEqual(session.remainingTime, 0)
    }

    func testRemainingTimeIsPositiveForRecentSession() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date(),
            maxDuration: 600
        )
        XCTAssertGreaterThan(session.remainingTime, 0)
        XCTAssertLessThanOrEqual(session.remainingTime, 600)
    }

    func testRemainingTimeDecreasesAsTimeElapses() {
        // Session created 100 seconds ago with 600s max
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date().addingTimeInterval(-100),
            maxDuration: 600
        )
        // Remaining should be approximately 500s
        XCTAssertLessThanOrEqual(session.remainingTime, 500)
        XCTAssertGreaterThan(session.remainingTime, 490)
    }

    func testRemainingTimeNeverExceedsMaxDuration() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date(),
            maxDuration: 300
        )
        XCTAssertLessThanOrEqual(session.remainingTime, 300)
    }

    func testRemainingTimeEqualsMaxDurationWhenJustCreated() {
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date(),
            maxDuration: 600
        )
        // Just created, so remainingTime should be very close to maxDuration
        XCTAssertEqual(session.remainingTime, 600, accuracy: 1.0)
    }

    func testRemainingTimeIsZeroWhenExactlyExpired() {
        // Created exactly maxDuration seconds ago
        let session = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/live.m3u8")!,
            createdAt: Date().addingTimeInterval(-600),
            maxDuration: 600
        )
        XCTAssertEqual(session.remainingTime, 0, accuracy: 1.0)
    }

    // MARK: - Equatable

    func testEquatableForEqualSessions() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://ring.com/live.m3u8")!
        let a = StreamSession(deviceId: 1, hlsURL: url, createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 1, hlsURL: url, createdAt: date, maxDuration: 600)
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentDeviceId() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://ring.com/live.m3u8")!
        let a = StreamSession(deviceId: 1, hlsURL: url, createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 2, hlsURL: url, createdAt: date, maxDuration: 600)
        XCTAssertNotEqual(a, b)
    }

    func testEquatableForDifferentURL() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/a.m3u8")!,
            createdAt: date,
            maxDuration: 600
        )
        let b = StreamSession(
            deviceId: 1,
            hlsURL: URL(string: "https://ring.com/b.m3u8")!,
            createdAt: date,
            maxDuration: 600
        )
        XCTAssertNotEqual(a, b)
    }

    func testEquatableForDifferentMaxDuration() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://ring.com/live.m3u8")!
        let a = StreamSession(deviceId: 1, hlsURL: url, createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 1, hlsURL: url, createdAt: date, maxDuration: 300)
        XCTAssertNotEqual(a, b)
    }
}


// MARK: - StreamSessionResponse Tests

final class StreamSessionResponseTests: XCTestCase {

    // MARK: - JSON Decoding with snake_case keys

    func testDecodingFromSnakeCaseJSON() throws {
        let json = """
        {
            "device_id": 42,
            "hls_url": "https://ring.com/live/42.m3u8",
            "max_duration": 600
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamSessionResponse.self, from: json)

        XCTAssertEqual(response.deviceId, 42)
        XCTAssertEqual(response.hlsURL, "https://ring.com/live/42.m3u8")
        XCTAssertEqual(response.maxDuration, 600)
    }

    // MARK: - toDomain()

    func testToDomainProducesCorrectStreamSession() {
        let response = StreamSessionResponse(
            deviceId: 42,
            hlsURL: "https://ring.com/live/42.m3u8",
            maxDuration: 600
        )

        let before = Date()
        let session = response.toDomain()
        let after = Date()

        XCTAssertEqual(session.deviceId, 42)
        XCTAssertEqual(session.hlsURL, URL(string: "https://ring.com/live/42.m3u8")!)
        XCTAssertEqual(session.maxDuration, 600)

        // createdAt should be approximately now
        XCTAssertGreaterThanOrEqual(session.createdAt, before)
        XCTAssertLessThanOrEqual(session.createdAt, after)
    }

    func testToDomainSessionIsValid() {
        let response = StreamSessionResponse(
            deviceId: 1,
            hlsURL: "https://ring.com/live.m3u8",
            maxDuration: 600
        )

        let session = response.toDomain()
        XCTAssertTrue(session.isValid)
    }

    func testToDomainWithZeroMaxDuration() {
        let response = StreamSessionResponse(
            deviceId: 1,
            hlsURL: "https://ring.com/live.m3u8",
            maxDuration: 0
        )

        let session = response.toDomain()
        XCTAssertFalse(session.isValid)
        XCTAssertEqual(session.remainingTime, 0)
    }

    func testToDomainWithInvalidURLFallsBack() {
        let response = StreamSessionResponse(
            deviceId: 1,
            hlsURL: "",
            maxDuration: 600
        )

        let session = response.toDomain()
        // Falls back to about:blank for invalid URL
        XCTAssertEqual(session.hlsURL, URL(string: "about:blank")!)
    }
}
