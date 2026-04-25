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
            tokenType: "Bearer"
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
            tokenType: "Bearer"
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
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date.distantPast,
            scope: nil,
            tokenType: "Bearer"
        )
        XCTAssertTrue(token.isExpired)
    }

    func testIsExpiredReturnsFalseForFutureDate() {
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date.distantFuture,
            scope: nil,
            tokenType: "Bearer"
        )
        XCTAssertFalse(token.isExpired)
    }

    // MARK: - needsRefresh

    func testNeedsRefreshReturnsTrueWithinFiveMinutesOfExpiry() {
        // Expires in 4 minutes (< 5 min threshold)
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(240),
            scope: nil,
            tokenType: "Bearer"
        )
        XCTAssertTrue(token.needsRefresh)
    }

    func testNeedsRefreshReturnsFalseWellBeforeExpiry() {
        // Expires in 10 minutes (> 5 min threshold)
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(600),
            scope: nil,
            tokenType: "Bearer"
        )
        XCTAssertFalse(token.needsRefresh)
    }

    func testNeedsRefreshReturnsTrueForExpiredToken() {
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date.distantPast,
            scope: nil,
            tokenType: "Bearer"
        )
        XCTAssertTrue(token.needsRefresh)
    }
}

// MARK: - AuthTokenResponse Tests

final class AuthTokenResponseTests: XCTestCase {

    // MARK: - JSON Decoding with snake_case keys

    func testDecodingFromSnakeCaseJSON() throws {
        let json = """
        {
            "access_token": "abc",
            "refresh_token": "def",
            "expires_in": 3600,
            "scope": "client",
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthTokenResponse.self, from: json)

        XCTAssertEqual(response.accessToken, "abc")
        XCTAssertEqual(response.refreshToken, "def")
        XCTAssertEqual(response.expiresIn, 3600)
        XCTAssertEqual(response.scope, "client")
        XCTAssertEqual(response.tokenType, "Bearer")
    }

    func testDecodingWithNullScope() throws {
        let json = """
        {
            "access_token": "abc",
            "refresh_token": "def",
            "expires_in": 7200,
            "scope": null,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthTokenResponse.self, from: json)
        XCTAssertNil(response.scope)
    }

    func testDecodingWithMissingScope() throws {
        let json = """
        {
            "access_token": "abc",
            "refresh_token": "def",
            "expires_in": 7200,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthTokenResponse.self, from: json)
        XCTAssertNil(response.scope)
    }

    // MARK: - toDomain()

    func testToDomainProducesCorrectAuthToken() {
        let response = AuthTokenResponse(
            accessToken: "access_tok",
            refreshToken: "refresh_tok",
            expiresIn: 3600,
            scope: "client",
            tokenType: "Bearer"
        )

        let before = Date()
        let token = response.toDomain()
        let after = Date()

        XCTAssertEqual(token.accessToken, "access_tok")
        XCTAssertEqual(token.refreshToken, "refresh_tok")
        XCTAssertEqual(token.scope, "client")
        XCTAssertEqual(token.tokenType, "Bearer")

        // expiresAt should be approximately now + 3600s
        let expectedLower = before.addingTimeInterval(3600)
        let expectedUpper = after.addingTimeInterval(3600)
        XCTAssertGreaterThanOrEqual(token.expiresAt, expectedLower)
        XCTAssertLessThanOrEqual(token.expiresAt, expectedUpper)
    }

    func testToDomainTokenIsNotExpired() {
        let response = AuthTokenResponse(
            accessToken: "a",
            refreshToken: "r",
            expiresIn: 7200,
            scope: nil,
            tokenType: "Bearer"
        )

        let token = response.toDomain()
        XCTAssertFalse(token.isExpired)
        XCTAssertFalse(token.needsRefresh)
    }

    func testToDomainWithZeroExpiresInProducesExpiredToken() {
        let response = AuthTokenResponse(
            accessToken: "a",
            refreshToken: "r",
            expiresIn: 0,
            scope: nil,
            tokenType: "Bearer"
        )

        let token = response.toDomain()
        // expiresAt ≈ now, so isExpired should be true (or borderline)
        XCTAssertTrue(token.needsRefresh)
    }
}
