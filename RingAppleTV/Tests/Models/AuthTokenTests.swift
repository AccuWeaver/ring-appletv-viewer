import XCTest
@testable import RingAppleTV

final class AuthTokenTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let token = AuthToken(
            accessToken: "access123",
            refreshToken: "refresh456",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            scope: "client",
            tokenType: "Bearer",
            clientId: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(token)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(AuthToken.self, from: data)

        XCTAssertEqual(decoded, token)
    }

    func testCodableRoundTripWithNilScope() throws {
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 1_000_000),
            scope: nil,
            tokenType: "Bearer",
            clientId: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(token)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(AuthToken.self, from: data)

        XCTAssertEqual(decoded, token)
        XCTAssertNil(decoded.scope)
    }

    // MARK: - isExpired

    func testIsExpiredReturnsTrueForPastDate() {
        let token = AuthToken(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date.distantPast, scope: nil,
            tokenType: "Bearer", clientId: nil
        )
        XCTAssertTrue(token.isExpired)
    }

    func testIsExpiredReturnsFalseForFutureDate() {
        let token = AuthToken(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date.distantFuture, scope: nil,
            tokenType: "Bearer", clientId: nil
        )
        XCTAssertFalse(token.isExpired)
    }

    // MARK: - needsRefresh (60s threshold)

    func testNeedsRefreshReturnsTrueWithin60SecondsOfExpiry() {
        // Expires in 30 seconds (< 60s threshold)
        let token = AuthToken(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(30), scope: nil,
            tokenType: "Bearer", clientId: nil
        )
        XCTAssertTrue(token.needsRefresh)
    }

    func testNeedsRefreshReturnsFalseWellBeforeExpiry() {
        // Expires in 10 minutes (> 60s threshold)
        let token = AuthToken(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(600), scope: nil,
            tokenType: "Bearer", clientId: nil
        )
        XCTAssertFalse(token.needsRefresh)
    }

    func testNeedsRefreshReturnsTrueForExpiredToken() {
        let token = AuthToken(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date.distantPast, scope: nil,
            tokenType: "Bearer", clientId: nil
        )
        XCTAssertTrue(token.needsRefresh)
    }

    // MARK: - clientId

    func testClientIdIsPreserved() throws {
        let token = AuthToken(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), scope: nil,
            tokenType: "Bearer", clientId: "my-client-id"
        )
        XCTAssertEqual(token.clientId, "my-client-id")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(AuthToken.self, from: data)
        XCTAssertEqual(decoded.clientId, "my-client-id")
    }
}

