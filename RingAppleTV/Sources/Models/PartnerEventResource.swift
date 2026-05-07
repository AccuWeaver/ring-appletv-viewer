import Foundation

/// DTO for a Partner API event resource.
/// Maps snake_case JSON keys to Swift properties and converts to the domain `RingEvent`.
struct PartnerEventResource: Codable, Equatable {
    let id: String
    let deviceId: String
    let type: String
    let createdAt: String
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case type
        case createdAt = "created_at"
        case duration
    }

    /// Converts the Partner API event into a domain `RingEvent`.
    ///
    /// Parses `createdAt` as ISO 8601; falls back to the current date on failure.
    func toDomain() -> RingEvent {
        let formatter = ISO8601DateFormatter()
        return RingEvent(
            id: id,
            deviceId: deviceId,
            eventType: RingEvent.EventType(rawValue: type) ?? .motion,
            createdAt: formatter.date(from: createdAt) ?? Date(),
            duration: duration.map { TimeInterval($0) }
        )
    }
}
