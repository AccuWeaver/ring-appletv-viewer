import Foundation

/// DTO for the JSON response from Ring's event history endpoint.
/// Maps snake_case JSON keys to Swift properties and converts to the domain `RingEvent`.
struct RingEventResponse: Codable {
    let id: Int
    let deviceId: Int
    let deviceName: String
    let kind: String
    let createdAt: String
    let duration: Int?
    let thumbnailURL: String?
    let videoAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case deviceName = "device_name"
        case kind
        case createdAt = "created_at"
        case duration
        case thumbnailURL = "thumbnail_url"
        case videoAvailable = "video_available"
    }

    /// Converts the API response into a domain `RingEvent`.
    func toDomain() -> RingEvent {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: createdAt) ?? Date()

        return RingEvent(
            id: id,
            deviceId: deviceId,
            deviceName: deviceName,
            eventType: RingEvent.EventType(rawValue: kind) ?? .motion,
            createdAt: date,
            duration: duration.map { TimeInterval($0) },
            thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
            videoAvailable: videoAvailable
        )
    }
}
