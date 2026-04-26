import Foundation

/// Domain model representing a live stream session from a Ring device.
///
/// Ring uses SIP/WebRTC for live streaming, not HLS. This model captures
/// the session metadata. Actual video playback requires a WebRTC client
/// implementation (future work).
struct StreamSession: Codable, Equatable {
    let deviceId: Int
    let sipServerIp: String?
    let sipServerPort: Int?
    let sipSessionId: String?
    let protocol_: String
    let createdAt: Date
    let maxDuration: TimeInterval

    /// Whether the stream session still has remaining time.
    var isValid: Bool {
        remainingTime > 0
    }

    /// Seconds remaining before the session expires. Always >= 0.
    var remainingTime: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(createdAt))
    }

    /// Whether this is a SIP-based session (which requires WebRTC).
    var isSipSession: Bool {
        protocol_ == "sip"
    }
}
