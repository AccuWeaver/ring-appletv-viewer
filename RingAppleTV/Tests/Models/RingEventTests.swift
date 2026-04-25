import XCTest
@testable import RingAppleTV

final class RingEventTests: XCTestCase {

    // MARK: - Helpers

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let event = RingEvent(
            id: 100,
            deviceId: 42,
            deviceName: "Front Door",
            eventType: .ding,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30.5,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            videoAvailable: true
        )

        let data = try makeEncoder().encode(event)
        let decoded = try makeDecoder().decode(RingEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    func testCodableRoundTripWithAllNilOptionals() throws {
        let event = RingEvent(
            id: 1,
            deviceId: 2,
            deviceName: "Cam",
            eventType: .motion,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            duration: nil,
            thumbnailURL: nil,
            videoAvailable: false
        )

        let data = try makeEncoder().encode(event)
        let decoded = try makeDecoder().decode(RingEvent.self, from: data)

        XCTAssertEqual(decoded, event)
        XCTAssertNil(decoded.duration)
        XCTAssertNil(decoded.thumbnailURL)
    }

    func testCodableRoundTripOnDemandEventType() throws {
        let event = RingEvent(
            id: 5,
            deviceId: 10,
            deviceName: "Back Yard",
            eventType: .onDemand,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            duration: 120.0,
            thumbnailURL: URL(string: "https://example.com/on_demand.jpg"),
            videoAvailable: true
        )

        let data = try makeEncoder().encode(event)
        let decoded = try makeDecoder().decode(RingEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    // MARK: - Identifiable

    func testIdentifiableConformance() {
        let event = RingEvent(
            id: 99,
            deviceId: 1,
            deviceName: "Garage",
            eventType: .motion,
            createdAt: Date(),
            duration: nil,
            thumbnailURL: nil,
            videoAvailable: false
        )

        XCTAssertEqual(event.id, 99)
    }

    // MARK: - Equatable

    func testEquatableForEqualEvents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: date, duration: 10.0, thumbnailURL: nil, videoAvailable: true
        )
        let b = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: date, duration: 10.0, thumbnailURL: nil, videoAvailable: true
        )
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentEvents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: date, duration: nil, thumbnailURL: nil, videoAvailable: true
        )
        let b = RingEvent(
            id: 2, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: date, duration: nil, thumbnailURL: nil, videoAvailable: true
        )
        XCTAssertNotEqual(a, b)
    }

    func testEquatableForDifferentEventTypes() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .motion,
            createdAt: date, duration: nil, thumbnailURL: nil, videoAvailable: false
        )
        let b = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: date, duration: nil, thumbnailURL: nil, videoAvailable: false
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Optional Properties

    func testOptionalDurationNil() {
        let event = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .motion,
            createdAt: Date(), duration: nil, thumbnailURL: nil, videoAvailable: false
        )
        XCTAssertNil(event.duration)
    }

    func testOptionalDurationPresent() {
        let event = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .motion,
            createdAt: Date(), duration: 45.0, thumbnailURL: nil, videoAvailable: false
        )
        XCTAssertEqual(event.duration, 45.0)
    }

    func testOptionalThumbnailURLNil() {
        let event = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: Date(), duration: nil, thumbnailURL: nil, videoAvailable: true
        )
        XCTAssertNil(event.thumbnailURL)
    }

    func testOptionalThumbnailURLPresent() {
        let url = URL(string: "https://example.com/thumb.jpg")!
        let event = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .ding,
            createdAt: Date(), duration: nil, thumbnailURL: url, videoAvailable: true
        )
        XCTAssertEqual(event.thumbnailURL, url)
    }

    func testVideoAvailableTrue() {
        let event = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .motion,
            createdAt: Date(), duration: nil, thumbnailURL: nil, videoAvailable: true
        )
        XCTAssertTrue(event.videoAvailable)
    }

    func testVideoAvailableFalse() {
        let event = RingEvent(
            id: 1, deviceId: 2, deviceName: "D", eventType: .motion,
            createdAt: Date(), duration: nil, thumbnailURL: nil, videoAvailable: false
        )
        XCTAssertFalse(event.videoAvailable)
    }
}

// MARK: - EventType Tests

final class EventTypeTests: XCTestCase {

    // MARK: - Raw Values

    func testMotionRawValue() {
        XCTAssertEqual(RingEvent.EventType.motion.rawValue, "motion")
    }

    func testDingRawValue() {
        XCTAssertEqual(RingEvent.EventType.ding.rawValue, "ding")
    }

    func testOnDemandRawValue() {
        XCTAssertEqual(RingEvent.EventType.onDemand.rawValue, "on_demand")
    }

    // MARK: - Display Names

    func testMotionDisplayName() {
        XCTAssertEqual(RingEvent.EventType.motion.displayName, "Motion Detected")
    }

    func testDingDisplayName() {
        XCTAssertEqual(RingEvent.EventType.ding.displayName, "Doorbell Press")
    }

    func testOnDemandDisplayName() {
        XCTAssertEqual(RingEvent.EventType.onDemand.displayName, "On Demand")
    }

    // MARK: - Icon Names

    func testMotionIconName() {
        XCTAssertEqual(RingEvent.EventType.motion.iconName, "figure.walk")
    }

    func testDingIconName() {
        XCTAssertEqual(RingEvent.EventType.ding.iconName, "bell.fill")
    }

    func testOnDemandIconName() {
        XCTAssertEqual(RingEvent.EventType.onDemand.iconName, "video.fill")
    }

    // MARK: - Codable

    func testEventTypeCodableRoundTrip() throws {
        let allTypes: [RingEvent.EventType] = [.motion, .ding, .onDemand]
        for eventType in allTypes {
            let data = try JSONEncoder().encode(eventType)
            let decoded = try JSONDecoder().decode(RingEvent.EventType.self, from: data)
            XCTAssertEqual(decoded, eventType)
        }
    }

    func testEventTypeDecodesFromRawValueJSON() throws {
        let json = "\"on_demand\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RingEvent.EventType.self, from: json)
        XCTAssertEqual(decoded, .onDemand)
    }

    // MARK: - Unknown Raw Values

    func testUnrecognizedStringProducesNil() {
        XCTAssertNil(RingEvent.EventType(rawValue: "unknown_type"))
    }

    func testEmptyStringProducesNil() {
        XCTAssertNil(RingEvent.EventType(rawValue: ""))
    }

    func testKnownRawValueRoundTrips() {
        let allTypes: [RingEvent.EventType] = [.motion, .ding, .onDemand]
        for eventType in allTypes {
            XCTAssertEqual(
                RingEvent.EventType(rawValue: eventType.rawValue),
                eventType,
                "Round-trip failed for \(eventType)"
            )
        }
    }
}
