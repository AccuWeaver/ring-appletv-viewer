import Foundation
import os

/// Hits the partner-auth backend's simulator-HLS bridge endpoint. When the
/// backend is running with `RING_ADAPTER=unofficial`, this asks the SIP bridge
/// sidecar to start a Ring SIP session, republish the RTP as RTSP to mediamtx,
/// and returns the mediamtx HLS URL the simulator can actually play.
///
/// Errors from this service are swallowed by the caller, which then falls back
/// to the recorded-event or test-pattern path.
final class DefaultSimulatorLiveStreamService: SimulatorLiveStreamService, @unchecked Sendable {

    /// Parsed shape of the backend's HLS-session response.
    private struct Response: Decodable {
        let session_id: String
        let hls_url: String
    }

    private let backendBaseURL: String
    private let session: URLSession
    private let logger = Logger(subsystem: "com.ringappletv", category: "SimulatorLiveStream")

    /// Request timeout for the HLS-session handshake. Matches the sidecar's
    /// 15 s SIP-start budget with a little headroom.
    private static let startTimeout: TimeInterval = 20

    init(backendBaseURL: String, session: URLSession = .shared) {
        self.backendBaseURL = backendBaseURL
        self.session = session
    }

    func startStream(deviceId: String) async throws -> SimulatorLiveStream {
        let endpoint = "\(backendBaseURL)/mock/devices/\(deviceId)/media/streaming/hls/sessions"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.startTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            logger.debug("HLS session rejected status=\(http.statusCode, privacy: .public)")
            throw URLError(.init(rawValue: http.statusCode))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let hls = URL(string: decoded.hls_url) else {
            throw URLError(.cannotParseResponse)
        }

        // Poll the HLS playlist URL until it returns 200 with content.
        // The sidecar needs 10-15s to authenticate with Ring, start the
        // live call, and produce the first segment. AVPlayer gives up
        // immediately on a 404, so we wait here.
        try await waitForPlaylist(url: hls)

        return SimulatorLiveStream(url: hls, sessionId: decoded.session_id)
    }

    /// Poll the HLS playlist URL every 2s for up to 30s until it returns
    /// a non-empty 200 response. Throws if the timeout expires.
    private func waitForPlaylist(url: URL) async throws {
        let maxAttempts = 15
        let pollInterval: UInt64 = 2_000_000_000 // 2s in nanoseconds

        for attempt in 1...maxAttempts {
            var probeRequest = URLRequest(url: url)
            probeRequest.timeoutInterval = 3
            do {
                let (data, response) = try await session.data(for: probeRequest)
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 200,
                   data.count > 50 { // playlist with at least one segment
                    logger.debug("HLS playlist ready after \(attempt, privacy: .public) attempts")
                    return
                }
            } catch {
                // 404 or network error — keep polling
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }
        logger.debug("HLS playlist not ready after \(maxAttempts, privacy: .public) attempts, proceeding anyway")
        // Don't throw — let AVPlayer try anyway; it might work by now
    }

    func releaseSession(_ sessionId: String) async {
        let endpoint = "\(backendBaseURL)/mock/session/\(sessionId)"
        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        do {
            _ = try await session.data(for: request)
        } catch {
            logger.debug("HLS session release failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
