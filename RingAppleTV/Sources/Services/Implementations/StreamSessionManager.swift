#if canImport(WebRTC)
import Foundation
import Combine
import WebRTC

// MARK: - StreamSessionManager (WebRTC Available)

/// Production implementation of `StreamSessionManagerProtocol`.
///
/// Orchestrates the full WHEP + WebRTC live stream lifecycle:
/// 1. Creates `RTCPeerConnection` in receive-only mode (no local tracks)
/// 2. Generates SDP offer
/// 3. Sends offer to WHEP endpoint via `PartnerAPIClient.createWHEPSession()`
/// 4. Applies SDP answer as remote description
/// 5. Waits for ICE `connected` state
/// 6. Starts session duration timer based on `PowerSource`
/// 7. On timer expiry or user stop: DELETE session, close `RTCPeerConnection`
/// 8. If DELETE fails: log error, still close local `RTCPeerConnection` (best-effort)
final class StreamSessionManager: NSObject, StreamSessionManagerProtocol, @unchecked Sendable {

    // MARK: - Published State

    @Published private(set) var connectionState: WebRTCConnectionState = .disconnected

    var connectionStatePublisher: Published<WebRTCConnectionState>.Publisher {
        $connectionState
    }

    // MARK: - Dependencies

    private let partnerAPIClient: PartnerAPIClientProtocol
    private let authService: AuthService

    // MARK: - WebRTC Resources

    private var peerConnection: RTCPeerConnection?
    private var peerConnectionFactory: RTCPeerConnectionFactory?
    @Published private(set) var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?

    // MARK: - Session State

    private var sessionURL: URL?
    private var sessionTimer: Task<Void, Never>?
    private var currentPowerSource: PowerSource?

    // MARK: - Configuration

    /// Connection timeout for WebRTC establishment.
    static let connectionTimeoutSeconds: TimeInterval = 30

    /// Default STUN server for ICE gathering.
    private static let defaultSTUNServers = ["stun:stun.l.google.com:19302"]

    // MARK: - Init

    init(partnerAPIClient: PartnerAPIClientProtocol, authService: AuthService) {
        self.partnerAPIClient = partnerAPIClient
        self.authService = authService
        super.init()
    }

    // MARK: - StreamSessionManagerProtocol

    func startStream(deviceId: String, powerSource: PowerSource) async throws {
        guard connectionState == .disconnected else { return }
        transitionState(to: .connecting)
        currentPowerSource = powerSource

        // Diagnostic breadcrumbs for device-specific crashes
        NSLog("[WEBRTC-DIAG] startStream called for device=\(deviceId)")

        do {
            let token = try await authService.getValidToken()
            NSLog("[WEBRTC-DIAG] got token, about to create encoder factory")

            let peerConn = try makePeerConnection()
            self.peerConnection = peerConn

            let constraints = Self.offerConstraints()

            // 2. Generate SDP offer
            let offerSDP = try await createOffer(peerConnection: peerConn, constraints: constraints)

            // 3. Send offer to WHEP endpoint via PartnerAPIClient
            let whepResponse = try await partnerAPIClient.createWHEPSession(
                deviceId: deviceId,
                sdpOffer: offerSDP,
                token: token.accessToken
            )
            self.sessionURL = whepResponse.sessionURL

            // 4. Apply SDP answer as remote description.
            // Munge the SDP to work around common WHEP server quirks:
            //  1. Reorder m-lines to match the offer (some servers return fewer/reordered m-lines)
            //  2. Ensure `a=rtcp-mux` is on every media section (required by modern WebRTC)
            let reorderedAnswerSDP = reorderMLinesToMatchOffer(
                offer: offerSDP,
                answer: whepResponse.sdpAnswer
            )
            let mungedAnswerSDP = ensureRtcpMux(in: reorderedAnswerSDP)
            NSLog("[WEBRTC-DIAG] munged SDP answer:\n%@", mungedAnswerSDP)
            let remoteSDP = RTCSessionDescription(type: .answer, sdp: mungedAnswerSDP)
            try await setRemoteDescription(peerConnection: peerConn, sdp: remoteSDP)

            // 5. Start session timer based on power source
            startSessionTimer(duration: powerSource.sessionDurationLimit)

            // 6. Start connection timeout
            startConnectionTimeout()
        } catch {
            transitionState(to: .failed(error.localizedDescription))
            await cleanupResources()
            throw error
        }
    }

    /// Build the ``RTCPeerConnectionFactory`` and ``RTCPeerConnection`` required
    /// for a WHEP session. Factored out of ``startStream`` to keep that function
    /// under SwiftLint's body-length limit; every side-effect stays in
    /// ``startStream`` so the control flow is still easy to audit.
    private func makePeerConnection() throws -> RTCPeerConnection {
        // 1a. Create encoder and decoder factories
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        NSLog("[WEBRTC-DIAG] encoder factory created")
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        NSLog("[WEBRTC-DIAG] decoder factory created")

        // 1b. Create peer connection factory with an injectable no-op audio device.
        // WebRTC's default iOS AudioDeviceModule fails to initialize on tvOS
        // (missing AVAudioSession APIs), causing the factory init to abort with
        // "Check failed: adm_" in webrtc_voice_engine.cc. A no-op RTCAudioDevice
        // bypasses that failure since we only need receive-only video (WHEP).
        NSLog("[WEBRTC-DIAG] about to call RTCPeerConnectionFactory init with NoOpAudioDevice")
        let audioDevice = NoOpAudioDevice()
        let factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioDevice: audioDevice
        )
        NSLog("[WEBRTC-DIAG] RTCPeerConnectionFactory created successfully")
        self.peerConnectionFactory = factory

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: Self.defaultSTUNServers)]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        guard let peerConn = factory.peerConnection(
            with: config,
            constraints: Self.offerConstraints(),
            delegate: self
        ) else {
            throw PartnerAPIError.networkError("Failed to create WebRTC peer connection")
        }
        return peerConn
    }

    private static func offerConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )
    }

    func stopStream() async {
        // Cancel session timer
        sessionTimer?.cancel()
        sessionTimer = nil

        // Best-effort DELETE to WHEP session
        if let url = sessionURL {
            do {
                let token = try await authService.getValidToken()
                try await partnerAPIClient.deleteWHEPSession(sessionURL: url, token: token.accessToken)
            } catch {
                // Best-effort — log and continue cleanup
            }
        }

        // Close local RTCPeerConnection and release resources
        releaseResources()

        // Transition to disconnected
        if connectionState != .disconnected {
            transitionState(to: .disconnected)
        }
    }

    // MARK: - State Machine

    /// Transitions to a new state only if the transition is valid.
    private func transitionState(to newState: WebRTCConnectionState) {
        guard connectionState.canTransition(to: newState) else { return }
        connectionState = newState
    }

    // MARK: - Session Timer

    /// Starts a timer that auto-stops the stream when the session duration expires.
    private func startSessionTimer(duration: TimeInterval) {
        sessionTimer?.cancel()
        sessionTimer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                await self?.stopStream()
            } catch {
                // Task was cancelled — no action needed
            }
        }
    }

    /// Starts a timeout that fails the connection if not yet connected.
    private func startConnectionTimeout() {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.connectionTimeoutSeconds) * 1_000_000_000)
                guard let self = self else { return }
                if self.connectionState == .connecting {
                    self.transitionState(to: .failed("Connection timed out"))
                    await self.cleanupResources()
                }
            } catch {
                // Task was cancelled — no action needed
            }
        }
    }

    // MARK: - Resource Cleanup

    private func cleanupResources() async {
        // Best-effort DELETE
        if let url = sessionURL {
            do {
                let token = try await authService.getValidToken()
                try await partnerAPIClient.deleteWHEPSession(sessionURL: url, token: token.accessToken)
            } catch {
                // Best-effort — continue cleanup
            }
        }
        releaseResources()
    }

    /// Releases all WebRTC resources.
    private func releaseResources() {
        videoTrack = nil
        audioTrack = nil

        peerConnection?.close()
        peerConnection = nil
        peerConnectionFactory = nil

        sessionURL = nil
        currentPowerSource = nil
    }

    // MARK: - SDP Helpers

    private func createOffer(
        peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { sdp, error in
                if let error = error {
                    let msg = "SDP offer creation failed: \(error.localizedDescription)"
                    continuation.resume(throwing: PartnerAPIError.networkError(msg))
                    return
                }
                guard let sdp = sdp else {
                    continuation.resume(throwing: PartnerAPIError.networkError("No SDP generated"))
                    return
                }
                peerConnection.setLocalDescription(sdp) { error in
                    if let error = error {
                        let msg = "Failed to set local description: \(error.localizedDescription)"
                        continuation.resume(throwing: PartnerAPIError.networkError(msg))
                    } else {
                        continuation.resume(returning: sdp.sdp)
                    }
                }
            }
        }
    }

    private func setRemoteDescription(
        peerConnection: RTCPeerConnection,
        sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(sdp) { error in
                if let error = error {
                    let msg = "Failed to apply remote SDP: \(error.localizedDescription)"
                    continuation.resume(throwing: PartnerAPIError.networkError(msg))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Reorder m-lines in an answer SDP to match the order of m-lines in the offer SDP.
    ///
    /// Modern WebRTC requires that the answer has the same m-lines in the same order
    /// as the offer. Some WHEP servers (including mediamtx) return only the m-lines
    /// they support, in their own preferred order. If our offer has `m=video m=audio`
    /// but the answer only returns `m=video`, we need to add a rejected `m=audio` line
    /// (port 0) in the right position.
    private func reorderMLinesToMatchOffer(offer: String, answer: String) -> String {
        // Extract the ordered list of media types from the offer
        let offerMTypes = Self.extractMediaTypes(from: offer)

        // Parse the answer into session-level lines + media sections keyed by m-line type
        let parsed = Self.parseSdpSections(answer)
        let answerSections = parsed.sections
        let sessionLines = parsed.sessionLines

        // If the answer already has all m-types in the same order as the offer, no change
        let answerMTypes = Array(answerSections.keys)
        if offerMTypes == answerMTypes.sorted() &&
           offerMTypes.count == answerMTypes.count &&
           Self.extractMediaTypes(from: answer) == offerMTypes {
            return answer
        }

        // Reassemble: session lines + media sections in offer order, inserting
        // rejected stubs for any missing sections
        var result = sessionLines
        for (midCounter, mtype) in offerMTypes.enumerated() {
            if let section = answerSections[mtype] {
                result.append(contentsOf: section)
            } else {
                // Add a rejected m-line (port 0) as a placeholder
                let placeholder = [
                    "m=\(mtype) 0 UDP/TLS/RTP/SAVPF 0",
                    "c=IN IP4 0.0.0.0",
                    "a=inactive",
                    "a=mid:\(midCounter)",
                ]
                result.append(contentsOf: placeholder)
            }
        }

        return result.joined(separator: "\r\n")
    }

    /// Return the ordered list of media types (``video``, ``audio``, ``application``,
    /// …) declared by ``m=…`` lines in an SDP string.
    private static func extractMediaTypes(from sdp: String) -> [String] {
        var mtypes: [String] = []
        for line in sdp.components(separatedBy: "\r\n") where line.hasPrefix("m=") {
            let parts = line.components(separatedBy: " ")
            guard let first = parts.first else { continue }
            mtypes.append(first.replacingOccurrences(of: "m=", with: ""))
        }
        return mtypes
    }

    private struct ParsedSdp {
        let sessionLines: [String]
        let sections: [String: [String]]
    }

    /// Split an SDP document into session-level lines and a dictionary of media
    /// sections keyed by their media type (``video``, ``audio``, …).
    private static func parseSdpSections(_ sdp: String) -> ParsedSdp {
        var sessionLines: [String] = []
        var sections: [String: [String]] = [:]
        var currentMType: String?
        var currentSection: [String] = []

        for line in sdp.components(separatedBy: "\r\n") {
            if line.hasPrefix("m=") {
                if let mtype = currentMType {
                    sections[mtype] = currentSection
                }
                let parts = line.components(separatedBy: " ")
                currentMType = parts.first?.replacingOccurrences(of: "m=", with: "")
                currentSection = [line]
            } else if currentMType == nil {
                sessionLines.append(line)
            } else {
                currentSection.append(line)
            }
        }
        if let mtype = currentMType {
            sections[mtype] = currentSection
        }
        return ParsedSdp(sessionLines: sessionLines, sections: sections)
    }

    /// Ensure every media section in an SDP has `a=rtcp-mux`.
    ///
    /// Modern WebRTC (M90+) requires rtcp-mux when BUNDLE is enabled, which is
    /// the default for peer connections with `sdpSemantics = .unifiedPlan`.
    /// Some WHEP servers (notably older versions of mediamtx) omit `a=rtcp-mux`
    /// from their answers, causing `setRemoteDescription` to reject with
    /// `INVALID_PARAMETER: rtcp-mux must be enabled when BUNDLE is enabled`.
    ///
    /// This function walks the SDP line by line and inserts `a=rtcp-mux` into
    /// any `m=` section that doesn't already have it.
    private func ensureRtcpMux(in sdp: String) -> String {
        var result: [String] = []
        var currentSection: [String] = []
        var currentSectionHasRtcpMux = false

        func flushSection() {
            guard !currentSection.isEmpty else { return }
            // Section starts with an m= line, so only insert if the section is a media section
            if currentSection.first?.hasPrefix("m=") == true, !currentSectionHasRtcpMux {
                // Insert after the m= line (position 1) so it comes before most other attrs
                currentSection.insert("a=rtcp-mux", at: 1)
            }
            result.append(contentsOf: currentSection)
            currentSection.removeAll()
            currentSectionHasRtcpMux = false
        }

        for line in sdp.components(separatedBy: "\r\n") {
            if line.hasPrefix("m=") {
                flushSection()
                currentSection.append(line)
            } else if currentSection.isEmpty {
                // Session-level header, pass through
                result.append(line)
            } else {
                if line == "a=rtcp-mux" {
                    currentSectionHasRtcpMux = true
                }
                currentSection.append(line)
            }
        }
        flushSection()

        return result.joined(separator: "\r\n")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension StreamSessionManager: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        NSLog("[WEBRTC-DIAG] signaling state changed: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Legacy Plan-B callback. Still called in some Unified Plan paths.
        NSLog(
            "[WEBRTC-DIAG] didAdd stream: video tracks=%d, audio tracks=%d",
            stream.videoTracks.count,
            stream.audioTracks.count
        )
        let video = stream.videoTracks.first
        let audio = stream.audioTracks.first
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.videoTrack == nil, let track = video {
                self.videoTrack = track
                NSLog("[WEBRTC-DIAG] video track assigned from didAdd stream")
            }
            if self.audioTrack == nil, let track = audio {
                self.audioTrack = track
            }
        }
    }

    // Unified Plan: tracks come via didAddReceiver, not didAdd stream.
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        NSLog("[WEBRTC-DIAG] didAdd rtpReceiver: track kind=\(rtpReceiver.track?.kind ?? "nil")")
        if let videoRTCTrack = rtpReceiver.track as? RTCVideoTrack {
            DispatchQueue.main.async { [weak self] in
                self?.videoTrack = videoRTCTrack
                NSLog("[WEBRTC-DIAG] video track assigned from didAddReceiver")
            }
        } else if let audioRTCTrack = rtpReceiver.track as? RTCAudioTrack {
            DispatchQueue.main.async { [weak self] in
                self?.audioTrack = audioRTCTrack
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        // Stream removed — clean up tracks if they belong to this stream
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // Re-negotiation not needed for receive-only streams
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        NSLog("[WEBRTC-DIAG] ICE connection state: \(newState.rawValue)")
        switch newState {
        case .connected, .completed:
            transitionState(to: .connected)
        case .failed:
            transitionState(to: .failed("ICE connection failed"))
            // Best-effort cleanup on ICE failure
            Task { await cleanupResources() }
        case .disconnected, .closed:
            if connectionState == .connected {
                transitionState(to: .disconnected)
            }
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        NSLog("[WEBRTC-DIAG] ICE gathering state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // WHEP bundles ICE candidates in the initial SDP exchange — no trickle needed
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Candidate removal — not typically needed
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Data channels not used for Ring live streams
    }
}

#else

// MARK: - StreamSessionManager Stub (WebRTC Not Available)

import Foundation
import Combine

/// Stub implementation when WebRTC framework is not available.
/// All stream operations throw an error indicating WebRTC is unavailable.
final class StreamSessionManager: StreamSessionManagerProtocol, @unchecked Sendable {

    @Published private(set) var connectionState: WebRTCConnectionState = .disconnected

    var connectionStatePublisher: Published<WebRTCConnectionState>.Publisher {
        $connectionState
    }

    private let partnerAPIClient: PartnerAPIClientProtocol
    private let authService: AuthService

    init(partnerAPIClient: PartnerAPIClientProtocol, authService: AuthService) {
        self.partnerAPIClient = partnerAPIClient
        self.authService = authService
    }

    func startStream(deviceId: String, powerSource: PowerSource) async throws {
        throw PartnerAPIError.networkError("WebRTC is not available on this platform")
    }

    func stopStream() async {
        // No-op when WebRTC is unavailable
    }
}

#endif
