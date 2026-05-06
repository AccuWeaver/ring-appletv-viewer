import Foundation

/// Domain model representing a Ring camera event (motion, doorbell press, or on-demand recording).
struct RingEvent: Codable, Identifiable, Equatable {
    let id: String
    let deviceId: String
    let eventType: EventType
    let createdAt: Date
    let duration: TimeInterval?

    // MARK: - EventType

    enum EventType: String, Codable {
        case motion = "motion"
        case ding = "ding"
        case onDemand = "on_demand"

        var displayName: String {
            switch self {
            case .motion: return "Motion Detected"
            case .ding: return "Doorbell Press"
            case .onDemand: return "On Demand"
            }
        }

        var iconName: String {
            switch self {
            case .motion: return "figure.walk"
            case .ding: return "bell.fill"
            case .onDemand: return "video.fill"
            }
        }
    }
}
