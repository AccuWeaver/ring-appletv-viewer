import XCTest
@testable import RingAppleTV

final class StreamSessionTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let session = StreamSession(
            deviceId: 42,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
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
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
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
        XCTAssertEqual(decoded.sipServerIp, "52.12.182.65")
        XCTAssertEqual(decoded.sipServerPort, 15064)
        XCTAssertEqual(decoded.sipSessionId, "test-session")
        XCTAssertEqual(decoded.protocol_, "sip")
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(decoded.maxDuration, 300)
    }

    // MARK: - isValid

    func testIsValidReturnsTrueForRecentSession() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 600
        )
        XCTAssertTrue(session.isValid)
    }

    func testIsValidReturnsFalseForExpiredSession() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date.distantPast,
            maxDuration: 600
        )
        XCTAssertFalse(session.isValid)
    }

    func testIsValidReturnsFalseWhenMaxDurationIsZero() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 0
        )
        XCTAssertFalse(session.isValid)
    }

    // MARK: - remainingTime

    func testRemainingTimeIsNonNegativeForExpiredSession() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date.distantPast,
            maxDuration: 600
        )
        XCTAssertEqual(session.remainingTime, 0)
    }

    func testRemainingTimeIsPositiveForRecentSession() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
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
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
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
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 300
        )
        XCTAssertLessThanOrEqual(session.remainingTime, 300)
    }

    func testRemainingTimeEqualsMaxDurationWhenJustCreated() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
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
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date().addingTimeInterval(-600),
            maxDuration: 600
        )
        XCTAssertEqual(session.remainingTime, 0, accuracy: 1.0)
    }

    // MARK: - isSipSession

    func testIsSipSessionReturnsTrueForSipProtocol() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 600
        )
        XCTAssertTrue(session.isSipSession)
    }

    func testIsSipSessionReturnsFalseForOtherProtocol() {
        let session = StreamSession(
            deviceId: 1,
            sipServerIp: nil,
            sipServerPort: nil,
            sipSessionId: nil,
            protocol_: "webrtc",
            createdAt: Date(),
            maxDuration: 600
        )
        XCTAssertFalse(session.isSipSession)
    }

    // MARK: - Equatable

    func testEquatableForEqualSessions() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = StreamSession(deviceId: 1, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 1, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentDeviceId() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = StreamSession(deviceId: 1, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 2, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        XCTAssertNotEqual(a, b)
    }

    func testEquatableForDifferentSipServerIp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = StreamSession(deviceId: 1, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 1, sipServerIp: "10.0.0.1", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        XCTAssertNotEqual(a, b)
    }

    func testEquatableForDifferentMaxDuration() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = StreamSession(deviceId: 1, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 600)
        let b = StreamSession(deviceId: 1, sipServerIp: "52.12.182.65", sipServerPort: 15064, sipSessionId: "test-session", protocol_: "sip", createdAt: date, maxDuration: 300)
        XCTAssertNotEqual(a, b)
    }
}


// MARK: - StreamSessionResponse Tests

final class StreamSessionResponseTests: XCTestCase {

    // MARK: - JSON Decoding with snake_case keys

    func testDecodingFromSnakeCaseJSON() throws {
        let json = """
        {
            "doorbot_id": 42,
            "sip_server_ip": "52.12.182.65",
            "sip_server_port": 15064,
            "sip_server_tls": true,
            "sip_session_id": "test-session-id",
            "sip_from": "sip:device@ring.com",
            "sip_to": "sip:session@52.12.182.65:15064",
            "sip_token": "",
            "sip_endpoints": null,
            "expires_in": 600,
            "protocol": "sip",
            "state": "ringing"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamSessionResponse.self, from: json)

        XCTAssertEqual(response.doorbotId, 42)
        XCTAssertEqual(response.sipServerIp, "52.12.182.65")
        XCTAssertEqual(response.sipServerPort, 15064)
        XCTAssertEqual(response.sipServerTls, true)
        XCTAssertEqual(response.sipSessionId, "test-session-id")
        XCTAssertEqual(response.protocol_, "sip")
        XCTAssertEqual(response.expiresIn, 600)
    }

    // MARK: - toDomain()

    func testToDomainProducesCorrectStreamSession() {
        let response = StreamSessionResponse(
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipServerTls: true,
            sipSessionId: "test-session",
            sipFrom: "sip:test@ring.com",
            sipTo: "sip:device@52.12.182.65:15064",
            sipToken: "",
            sipEndpoints: nil,
            doorbotId: 42,
            expiresIn: 600,
            protocol_: "sip",
            state: "ringing"
        )

        let before = Date()
        let session = response.toDomain()
        let after = Date()

        XCTAssertEqual(session.deviceId, 42)
        XCTAssertEqual(session.sipServerIp, "52.12.182.65")
        XCTAssertEqual(session.sipServerPort, 15064)
        XCTAssertEqual(session.sipSessionId, "test-session")
        XCTAssertEqual(session.protocol_, "sip")
        XCTAssertEqual(session.maxDuration, 600)

        // createdAt should be approximately now
        XCTAssertGreaterThanOrEqual(session.createdAt, before)
        XCTAssertLessThanOrEqual(session.createdAt, after)
    }

    func testToDomainSessionIsValid() {
        let response = StreamSessionResponse(
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipServerTls: true,
            sipSessionId: "test-session",
            sipFrom: "sip:test@ring.com",
            sipTo: "sip:device@52.12.182.65:15064",
            sipToken: "",
            sipEndpoints: nil,
            doorbotId: 1,
            expiresIn: 600,
            protocol_: "sip",
            state: "ringing"
        )

        let session = response.toDomain()
        XCTAssertTrue(session.isValid)
    }

    func testToDomainWithZeroExpiresIn() {
        let response = StreamSessionResponse(
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipServerTls: true,
            sipSessionId: "test-session",
            sipFrom: "sip:test@ring.com",
            sipTo: "sip:device@52.12.182.65:15064",
            sipToken: "",
            sipEndpoints: nil,
            doorbotId: 1,
            expiresIn: 0,
            protocol_: "sip",
            state: "ringing"
        )

        let session = response.toDomain()
        XCTAssertFalse(session.isValid)
        XCTAssertEqual(session.remainingTime, 0)
    }

    func testToDomainWithNilExpiresInDefaultsTo600() {
        let response = StreamSessionResponse(
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipServerTls: true,
            sipSessionId: "test-session",
            sipFrom: "sip:test@ring.com",
            sipTo: "sip:device@52.12.182.65:15064",
            sipToken: "",
            sipEndpoints: nil,
            doorbotId: 1,
            expiresIn: nil,
            protocol_: "sip",
            state: "ringing"
        )

        let session = response.toDomain()
        XCTAssertEqual(session.maxDuration, 600)
        XCTAssertTrue(session.isValid)
    }
}
