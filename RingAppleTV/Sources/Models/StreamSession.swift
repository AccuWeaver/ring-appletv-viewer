import Foundation

/// Domain model representing a live stream session from a Ring device.
///
/// Uses WHEP (WebRTC-HTTP Egress Protocol) for live streaming. The session URL
/// is the WHEP resource URL used for session termination via HTTP DELETE.
/// Session duration is derived from the device's power source.
struct StreamSession: Equatable {
    let deviceId: String
    let sessionURL: URL
    let powerSource: PowerSource
    let createdAt: Date

    /// Maximum allowed session duration, derived from the device's power source.
    var maxDuration: TimeInterval {
        powerSource.sessionDurationLimit
    }

    /// Whether the stream session still has remaining time.
    var isValid: Bool {
        remainingTime > 0
    }

    /// Seconds remaining before the session expires. Always >= 0.
    var remainingTime: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(createdAt))
    }
}
