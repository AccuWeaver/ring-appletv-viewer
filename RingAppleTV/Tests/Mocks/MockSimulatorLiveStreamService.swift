import Foundation
@testable import RingAppleTV

/// Test double for `SimulatorLiveStreamService` that records calls and lets
/// tests program the outcome of `startStream` / `releaseSession`.
final class MockSimulatorLiveStreamService: SimulatorLiveStreamService, @unchecked Sendable {
    /// Outcome returned from the next `startStream` call. Defaults to a
    /// network-style failure so tests that don't explicitly program a success
    /// naturally exercise the fallback path.
    var startStreamResult: Result<SimulatorLiveStream, Error> = .failure(URLError(.notConnectedToInternet))

    private(set) var startStreamCalls: [String] = []
    private(set) var releaseSessionCalls: [String] = []

    func startStream(deviceId: String) async throws -> SimulatorLiveStream {
        startStreamCalls.append(deviceId)
        return try startStreamResult.get()
    }

    func releaseSession(_ sessionId: String) async {
        releaseSessionCalls.append(sessionId)
    }
}
