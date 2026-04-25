import Foundation

/// Domain model representing an active HLS live stream session from a Ring device.
/// The session has a finite lifetime imposed by the API (`maxDuration`).
struct StreamSession: Codable, Equatable {
    let deviceId: Int
    let hlsURL: URL
    let createdAt: Date
    let maxDuration: TimeInterval // API-imposed limit

    /// Whether the stream session still has remaining time.
    var isValid: Bool {
        remainingTime > 0
    }

    /// Seconds remaining before the session expires. Always >= 0.
    var remainingTime: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(createdAt))
    }
}
