// WebRTCProofOfConcept.swift
// Minimal proof-of-concept for Task 1.4 — verifies WebRTC framework compiles and links on tvOS.
// This file is part of the WebRTC framework spike (FR-1).

#if canImport(WebRTC)
import WebRTC
import SwiftUI

/// Proof-of-concept: instantiate RTCPeerConnection on tvOS to verify the framework compiles and links.
///
/// This is NOT production code — it exists solely to validate that the `stasel/WebRTC` (tvOS fork)
/// package provides a working `RTCPeerConnection` and `RTCMTLVideoView` on tvOS.
enum WebRTCProofOfConcept {

    /// Returns `true` if an `RTCPeerConnection` can be created successfully.
    /// Call this on the tvOS simulator to confirm compile + link.
    static func canCreatePeerConnection() -> Bool {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        let factory = RTCPeerConnectionFactory()
        let peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: nil
        )

        let success = peerConnection != nil
        peerConnection?.close()
        return success
    }
}

/// Flag indicating whether the WebRTC framework is available at compile time.
/// Used by `ServiceContainer` to conditionally create `StreamSessionManager`.
let WebRTCFrameworkAvailable: Bool = true

// MARK: - WebRTC Test View

/// A standalone test view that verifies WebRTC video rendering works.
/// Creates a local loopback peer connection and renders through RTCMTLVideoView.
struct WebRTCTestView: View {
    @StateObject private var testManager = WebRTCTestManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if testManager.isRunning {
                if let track = testManager.videoTrack {
                    WebRTCVideoView(videoTrack: track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("WebRTC pipeline active — waiting for frames…")
                            .foregroundColor(.white)
                            .font(.system(size: 24))
                    }
                }
            } else {
                VStack(spacing: 32) {
                    Image(systemName: "video.badge.checkmark")
                        .font(.system(size: 72))
                        .foregroundColor(.blue)

                    Text("WebRTC Video Test")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    Text("Creates a local loopback peer connection\nand renders through the Metal video pipeline.")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        Text("PeerConnection: \(testManager.peerConnectionStatus)")
                            .foregroundColor(.green)
                        Text("Factory: \(testManager.factoryStatus)")
                            .foregroundColor(.green)
                    }
                    .font(.system(size: 18, design: .monospaced))

                    Button("Start Test") {
                        testManager.start()
                    }
                    .font(.system(size: 22, weight: .semibold))
                }
            }

            // Status overlay when running
            if testManager.isRunning {
                VStack {
                    HStack {
                        Spacer()
                        Button("Stop") {
                            testManager.stop()
                        }
                        .font(.system(size: 18))
                        .padding()
                    }
                    Spacer()
                    HStack {
                        Circle()
                            .fill(testManager.connectionEstablished ? Color.green : Color.orange)
                            .frame(width: 12, height: 12)
                        Text(testManager.statusMessage)
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .padding(.bottom, 40)
                }
            }
        }
    }
}

// MARK: - WebRTCTestManager

/// Connects to a local WHEP server (mediamtx) to receive and render real video.
/// Run: `mediamtx` then `ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -c:v libx264 -preset ultrafast -tune zerolatency -f rtsp rtsp://localhost:8554/test`
@MainActor
final class WebRTCTestManager: ObservableObject {
    @Published var isRunning = false
    @Published var videoTrack: RTCVideoTrack?
    @Published var connectionEstablished = false
    @Published var statusMessage = "Initializing…"
    @Published var peerConnectionStatus = "not tested"
    @Published var factoryStatus = "not tested"

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var delegate: WHEPDelegate?

    /// Local WHEP endpoint (mediamtx default)
    private let whepURL = "http://localhost:8889/test/whep"

    init() {
        let testFactory = RTCPeerConnectionFactory()
        factoryStatus = "✓ created"

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        if let pc = testFactory.peerConnection(with: config, constraints: constraints, delegate: nil) {
            peerConnectionStatus = "✓ created"
            pc.close()
        } else {
            peerConnectionStatus = "✗ failed"
        }
    }

    func start() {
        isRunning = true
        statusMessage = "Connecting to local WHEP server…"
        Task { await connectToWHEP() }
    }

    func stop() {
        peerConnection?.close()
        peerConnection = nil
        videoTrack = nil
        factory = nil
        delegate = nil
        isRunning = false
        connectionEstablished = false
        statusMessage = "Stopped"
    }

    private func connectToWHEP() async {
        let factory = RTCPeerConnectionFactory()
        self.factory = factory

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan

        let delegate = WHEPDelegate { [weak self] state in
            Task { @MainActor in self?.handleICEState(state) }
        } onTrack: { [weak self] track in
            Task { @MainActor in
                self?.videoTrack = track
                self?.statusMessage = "✓ Video track received — rendering!"
            }
        }
        self.delegate = delegate

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            statusMessage = "✗ Failed to create PeerConnection"
            isRunning = false
            return
        }
        self.peerConnection = pc

        // Add receive-only transceivers
        pc.addTransceiver(of: .video)?.setDirection(.recvOnly, error: nil)
        pc.addTransceiver(of: .audio)?.setDirection(.recvOnly, error: nil)

        statusMessage = "Creating SDP offer…"

        do {
            // Create offer
            let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
                pc.offer(for: constraints) { sdp, error in
                    if let error { cont.resume(throwing: error) }
                    else if let sdp { cont.resume(returning: sdp) }
                    else { cont.resume(throwing: NSError(domain: "whep", code: -1)) }
                }
            }

            // Set local description
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pc.setLocalDescription(offer) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }

            statusMessage = "Sending offer to WHEP server…"

            // Send offer to WHEP endpoint
            guard let url = URL(string: whepURL) else {
                statusMessage = "✗ Invalid WHEP URL"
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
            request.httpBody = offer.sdp.data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                statusMessage = "✗ Invalid response from WHEP"
                return
            }

            guard httpResponse.statusCode == 201 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                statusMessage = "✗ WHEP returned \(httpResponse.statusCode): \(body.prefix(100))"
                return
            }

            guard let answerSDP = String(data: data, encoding: .utf8) else {
                statusMessage = "✗ Could not decode SDP answer"
                return
            }

            statusMessage = "Applying SDP answer…"

            // Set remote description
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pc.setRemoteDescription(answer) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }

            statusMessage = "SDP exchange complete — waiting for ICE connection…"

        } catch {
            statusMessage = "✗ Error: \(error.localizedDescription)"
        }
    }

    private func handleICEState(_ state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed:
            connectionEstablished = true
            statusMessage = "✓ WebRTC connected — video streaming!"
        case .failed:
            statusMessage = "✗ ICE connection failed"
        case .disconnected:
            statusMessage = "Disconnected"
        default:
            break
        }
    }
}

// MARK: - WHEPDelegate

private final class WHEPDelegate: NSObject, RTCPeerConnectionDelegate {
    let onStateChange: (RTCIceConnectionState) -> Void
    let onTrack: (RTCVideoTrack) -> Void

    init(onStateChange: @escaping (RTCIceConnectionState) -> Void, onTrack: @escaping (RTCVideoTrack) -> Void) {
        self.onStateChange = onStateChange
        self.onTrack = onTrack
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first { onTrack(track) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onStateChange(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

#else

// MARK: - Stub when WebRTC is not available

import SwiftUI

/// WebRTC framework is not available — stub flag for conditional compilation.
let WebRTCFrameworkAvailable: Bool = false

struct WebRTCTestView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.slash")
                .font(.system(size: 72))
                .foregroundColor(.red)
            Text("WebRTC Not Available")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.white)
            Text("The WebRTC framework is not linked in this build.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#endif
