import XCTest
@testable import RingAppleTV

final class AppConfigurationTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultValues() {
        let config = AppConfiguration()

        XCTAssertFalse(config.useMocks)
        XCTAssertFalse(config.enableDebugLogging)
        XCTAssertEqual(config.streamTimeoutSeconds, 600)
        XCTAssertEqual(config.deviceRefreshInterval, 60)
        XCTAssertEqual(config.eventHistoryHours, 48)
        XCTAssertEqual(config.maxEventCount, 50)
        XCTAssertEqual(config.cacheExpirationSeconds, 300)
        XCTAssertTrue(config.enableCrashReporting)
        XCTAssertFalse(config.enableLocalAnalytics)
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let config = AppConfiguration(
            useMocks: true,
            enableDebugLogging: true,
            streamTimeoutSeconds: 120,
            deviceRefreshInterval: 30,
            eventHistoryHours: 24,
            maxEventCount: 100,
            cacheExpirationSeconds: 60,
            enableCrashReporting: false,
            enableLocalAnalytics: true
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded, config)
    }

    func testCodableRoundTripWithDefaults() throws {
        let config = AppConfiguration()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Partial JSON Decoding

    func testPartialJSONDecodingEmptyObject() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)
        let defaults = AppConfiguration()
        XCTAssertEqual(decoded, defaults)
    }

    func testPartialJSONDecodingOnlyUseMocks() throws {
        let json = """
        { "useMocks": true }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)
        XCTAssertTrue(decoded.useMocks)
        XCTAssertFalse(decoded.enableDebugLogging)
        XCTAssertEqual(decoded.streamTimeoutSeconds, 600)
    }

    // MARK: - Equatable

    func testEqualityForIdenticalConfigs() {
        let a = AppConfiguration()
        let b = AppConfiguration()
        XCTAssertEqual(a, b)
    }

    func testInequalityWhenPropertyDiffers() {
        let a = AppConfiguration()
        var b = AppConfiguration()
        b.maxEventCount = 999
        XCTAssertNotEqual(a, b)
    }
}
