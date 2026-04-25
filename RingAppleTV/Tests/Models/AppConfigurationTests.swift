import XCTest
@testable import RingAppleTV

final class AppConfigurationTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultValues() {
        let config = AppConfiguration()

        XCTAssertFalse(config.useMocks)
        XCTAssertFalse(config.enableDebugLogging)
        XCTAssertEqual(config.streamTimeoutSeconds, 600)
        XCTAssertEqual(config.maxStreamDuration, 600)
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
            maxStreamDuration: 300,
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

    // MARK: - Partial JSON Decoding (missing keys use defaults)

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
        // All other properties should keep their defaults
        XCTAssertFalse(decoded.enableDebugLogging)
        XCTAssertEqual(decoded.streamTimeoutSeconds, 600)
        XCTAssertEqual(decoded.maxStreamDuration, 600)
        XCTAssertEqual(decoded.deviceRefreshInterval, 60)
        XCTAssertEqual(decoded.eventHistoryHours, 48)
        XCTAssertEqual(decoded.maxEventCount, 50)
        XCTAssertEqual(decoded.cacheExpirationSeconds, 300)
        XCTAssertTrue(decoded.enableCrashReporting)
        XCTAssertFalse(decoded.enableLocalAnalytics)
    }

    func testPartialJSONDecodingSeveralKeys() throws {
        let json = """
        {
            "enableDebugLogging": true,
            "maxEventCount": 25,
            "enableCrashReporting": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)

        XCTAssertTrue(decoded.enableDebugLogging)
        XCTAssertEqual(decoded.maxEventCount, 25)
        XCTAssertFalse(decoded.enableCrashReporting)
        // Remaining defaults
        XCTAssertFalse(decoded.useMocks)
        XCTAssertEqual(decoded.streamTimeoutSeconds, 600)
        XCTAssertEqual(decoded.maxStreamDuration, 600)
        XCTAssertEqual(decoded.deviceRefreshInterval, 60)
        XCTAssertEqual(decoded.eventHistoryHours, 48)
        XCTAssertEqual(decoded.cacheExpirationSeconds, 300)
        XCTAssertFalse(decoded.enableLocalAnalytics)
    }

    // MARK: - Mutability

    func testAllPropertiesCanBeModified() {
        var config = AppConfiguration()

        config.useMocks = true
        config.enableDebugLogging = true
        config.streamTimeoutSeconds = 120
        config.maxStreamDuration = 300
        config.deviceRefreshInterval = 30
        config.eventHistoryHours = 24
        config.maxEventCount = 100
        config.cacheExpirationSeconds = 60
        config.enableCrashReporting = false
        config.enableLocalAnalytics = true

        XCTAssertTrue(config.useMocks)
        XCTAssertTrue(config.enableDebugLogging)
        XCTAssertEqual(config.streamTimeoutSeconds, 120)
        XCTAssertEqual(config.maxStreamDuration, 300)
        XCTAssertEqual(config.deviceRefreshInterval, 30)
        XCTAssertEqual(config.eventHistoryHours, 24)
        XCTAssertEqual(config.maxEventCount, 100)
        XCTAssertEqual(config.cacheExpirationSeconds, 60)
        XCTAssertFalse(config.enableCrashReporting)
        XCTAssertTrue(config.enableLocalAnalytics)
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
