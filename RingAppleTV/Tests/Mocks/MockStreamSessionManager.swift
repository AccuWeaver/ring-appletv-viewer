import Foundation
import Combine
@testable import RingAppleTV

/// Mock `StreamSessionManagerProtocol` with configurable connection state and call tracking.
/// Replaces `MockWebRTCStreamService` usage.
final class MockStreamSessionManager: StreamSessionManagerProtocol, @unchecked Sendable {

    // MARK: - Published State

    @Published private(set) var connectionState: WebRTCConnectionState = .disconnected

    var connectionStatePublisher: Published<WebRTCConnectionState>.Publisher {
        $connectionState
    }

    // MARK: - Call Tracking

    var startStreamCalls: [(deviceId: String, powerSource: PowerSource)] = []
    var stopStreamCalls: Int = 0
    var setAudioMutedCalls: [Bool] = []

    // MARK: - Configurable Behavior

    /// Error to throw from `startStream()`. If nil, start succeeds.
    var startStreamError: Error?

    /// When set, `startStream()` will automatically transition through these states in order.
    var autoTransitionStates: [WebRTCConnectionState] = []

    // MARK: - StreamSessionManagerProtocol

    func startStream(deviceId: String, powerSource: PowerSource) async throws {
        startStreamCalls.append((deviceId: deviceId, powerSource: powerSource))

        if let error = startStreamError {
            connectionState = .failed(error.localizedDescription)
            throw error
        }

        for state in autoTransitionStates {
            connectionState = state
        }
    }

    func stopStream() async {
        stopStreamCalls += 1
        connectionState = .disconnected
    }

    func setAudioMuted(_ muted: Bool) {
        setAudioMutedCalls.append(muted)
    }

    // MARK: - Test Helpers

    /// Simulate a state change from outside (e.g., session expiration).
    func simulateStateChange(_ state: WebRTCConnectionState) {
        connectionState = state
    }
}
