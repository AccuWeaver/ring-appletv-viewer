import XCTest
@testable import RingAppleTV

final class RingEventTests: XCTestCase {

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
            id: "100", deviceId: "42", eventType: .ding,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 30.5
        )
        let data = try makeEncoder().encode(event)
        let decoded = try makeDecoder().decode(RingEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testCodableRoundTripWithNilDuration() throws {
        let event = RingEvent(
            id: "1", deviceId: "2", eventType: .motion,
            createdAt: Date(timeIntervalSince1970: 1_000_000), duration: nil
        )
        let data = try makeEncoder().encode(event)
        let decoded = try makeDecoder().decode(RingEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertNil(decoded.duration)
    }

    // MARK: - Identifiable

    func testIdentifiableConformance() {
        let event = RingEvent(
            id: "99", deviceId: "1", eventType: .motion,
            createdAt: Date(), duration: nil
        )
        XCTAssertEqual(event.id, "99")
    }

    // MARK: - Equatable

    func testEquatableForEqualEvents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = RingEvent(id: "1", deviceId: "2", eventType: .ding, createdAt: date, duration: 10.0)
        let b = RingEvent(id: "1", deviceId: "2", eventType: .ding, createdAt: date, duration: 10.0)
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentEvents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = RingEvent(id: "1", deviceId: "2", eventType: .ding, createdAt: date, duration: nil)
        let b = RingEvent(id: "2", deviceId: "2", eventType: .ding, createdAt: date, duration: nil)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Optional Properties

    func testOptionalDurationNil() {
        let event = RingEvent(id: "1", deviceId: "2", eventType: .motion, createdAt: Date(), duration: nil)
        XCTAssertNil(event.duration)
    }

    func testOptionalDurationPresent() {
        let event = RingEvent(id: "1", deviceId: "2", eventType: .motion, createdAt: Date(), duration: 45.0)
        XCTAssertEqual(event.duration, 45.0)
    }
}

// MARK: - EventType Tests

final class EventTypeTests: XCTestCase {

    func testMotionRawValue() {
        XCTAssertEqual(RingEvent.EventType.motion.rawValue, "motion")
    }

    func testDingRawValue() {
        XCTAssertEqual(RingEvent.EventType.ding.rawValue, "ding")
    }

    func testOnDemandRawValue() {
        XCTAssertEqual(RingEvent.EventType.onDemand.rawValue, "on_demand")
    }

    func testMotionDisplayName() {
        XCTAssertEqual(RingEvent.EventType.motion.displayName, "Motion Detected")
    }

    func testDingDisplayName() {
        XCTAssertEqual(RingEvent.EventType.ding.displayName, "Doorbell Press")
    }

    func testOnDemandDisplayName() {
        XCTAssertEqual(RingEvent.EventType.onDemand.displayName, "On Demand")
    }

    func testEventTypeCodableRoundTrip() throws {
        let allTypes: [RingEvent.EventType] = [.motion, .ding, .onDemand]
        for eventType in allTypes {
            let data = try JSONEncoder().encode(eventType)
            let decoded = try JSONDecoder().decode(RingEvent.EventType.self, from: data)
            XCTAssertEqual(decoded, eventType)
        }
    }

    func testUnrecognizedStringProducesNil() {
        XCTAssertNil(RingEvent.EventType(rawValue: "unknown_type"))
    }
}
