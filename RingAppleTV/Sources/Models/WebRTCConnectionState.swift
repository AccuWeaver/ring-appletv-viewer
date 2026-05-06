import Foundation

// MARK: - WebRTC Connection State

/// Represents the state of a WebRTC peer connection.
///
/// Valid transitions:
/// - `disconnected → connecting → connected → disconnected`
/// - `disconnected → connecting → failed → disconnected`
enum WebRTCConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    /// Returns `true` if transitioning to `next` is a valid state change.
    func canTransition(to next: WebRTCConnectionState) -> Bool {
        switch (self, next) {
        case (.disconnected, .connecting):
            return true
        case (.connecting, .connected):
            return true
        case (.connecting, .failed):
            return true
        case (.connected, .disconnected):
            return true
        case (.failed, .disconnected):
            return true
        default:
            return false
        }
    }
}
