import SwiftUI
import AVKit

/// Full-screen video player for Ring live streams and event playback.
/// Displays snapshot backdrop for WebRTC sessions, with loading/error overlays and Siri Remote controls.
struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let device: RingDevice
    let snapshotData: Data?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .idle:
                Color.clear.onAppear {
                    Task {
                        await viewModel.requestStream(
                            for: device.id,
                            powerSource: device.powerSource
                        )
                    }
                }
            case .loading:
                loadingOverlay
            case .loaded(let session):
                playerContent(session: session)
            case .error(let message):
                errorOverlay(message: message)
            case .empty(let message):
                EmptyStateView(
                    message: message,
                    guidance: "This device may not support live streaming.",
                    iconName: "video.slash"
                )
            }
        }
        #if os(tvOS) || os(iOS)
        .navigationBarHidden(true)
        #endif
        .ignoresSafeArea()
        // Always-on focus + onExitCommand so the Menu button dismisses the
        // player from any state (idle, loading, loaded, error). Without the
        // outer focusable() the player isn't the first responder during
        // loading/error overlays, and Menu escapes the NavigationView and
        // quits the app.
        .focusable(true)
        .onExitCommand {
            dismiss()
        }
        .onDisappear {
            viewModel.stopStream()
        }
    }

    // MARK: - Player Content

    private func playerContent(session: StreamSession) -> some View {
        ZStack(alignment: .topLeading) {
            if viewModel.streamSessionManager != nil {
                webRTCContent
            } else {
                // No WebRTC — play an HLS stream via AVPlayer.
                // Used in mock mode (simulator) and when the WebRTC framework is
                // unavailable. On a real Apple TV with Ring credentials, the
                // WebRTC path above handles live streams.
                mockHLSPlayer(session: session)
            }

            // Device name overlay
            deviceNameOverlay
        }
        .overlay(alignment: .topTrailing) {
            sourceBanner(for: session.source)
        }
    }

    // MARK: - Source Banner

    /// Small pill in the top-right that tells the viewer where the current
    /// video is actually coming from. Hidden for the live WebRTC path so the
    /// real-camera experience stays uncluttered.
    @ViewBuilder
    private func sourceBanner(for source: StreamSource) -> some View {
        if let config = bannerConfig(for: source) {
            HStack(spacing: 8) {
                Image(systemName: config.iconName)
                    .font(.system(size: 18, weight: .semibold))
                Text(config.label)
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(config.background.opacity(0.85))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .padding(Constants.UI.cardPadding)
            .accessibilityLabel(Text(config.accessibilityLabel))
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private struct BannerConfig {
        let label: String
        let iconName: String
        let background: Color
        let accessibilityLabel: String
    }

    private func bannerConfig(for source: StreamSource) -> BannerConfig? {
        switch source {
        case .liveWebRTC:
            // Real live partner-API path; leave the frame clean.
            return nil
        case .liveHLSBridge:
            return BannerConfig(
                label: "Live via bridge",
                iconName: "dot.radiowaves.left.and.right",
                background: .blue,
                accessibilityLabel: "Live video via the local SIP bridge"
            )
        case .recordedEvent:
            return BannerConfig(
                label: "Recorded",
                iconName: "clock.arrow.circlepath",
                background: .orange,
                accessibilityLabel: "Most recent recorded event, not live"
            )
        case .testPattern:
            return BannerConfig(
                label: "Test pattern",
                iconName: "tv.and.hifispeaker.fill",
                background: .gray,
                accessibilityLabel: "Apple test video, no Ring footage available"
            )
        }
    }

    // MARK: - Mock HLS Player (simulator / dev)

    /// Returns the URL to play in the HLS fallback. If the PlayerViewModel
    /// managed to resolve the device's most recent recorded clip URL we play
    /// that; otherwise we fall back to Apple's BipBop test stream so the UI
    /// flow still works when the device has no recorded events.
    private static let bipBopFallbackURL: URL = {
        let urlString = "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
            + "bipbop_16x9/bipbop_16x9_variant.m3u8"
        return URL(string: urlString) ?? URL(fileURLWithPath: "/dev/null")
    }()

    private func mockHLSPlayer(session: StreamSession) -> some View {
        // Uses a custom AVPlayerLayer wrapper (HLSPlayerView) instead of AVKit's
        // VideoPlayer so the Menu button isn't captured by AVKit's player chrome —
        // our `.onExitCommand` handler on the parent view can receive it and dismiss.
        //
        // Source-based URL selection:
        //   - `.testPattern` → hard-coded BipBop fallback
        //   - everything else (`.liveHLSBridge`, `.recordedEvent`) → the session's
        //     resolved URL. We guard on the placeholder URL too in case a code
        //     path surfaces it without updating `source`.
        let url: URL = {
            if session.source == .testPattern
                || session.sessionURL == PlayerViewModel.placeholderMockSessionURL {
                return Self.bipBopFallbackURL
            }
            return session.sessionURL
        }()
        return HLSPlayerView(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("HLS stream for \(device.name)"))
    }

    // MARK: - WebRTC Content

    @ViewBuilder
    private var webRTCContent: some View {
        switch viewModel.connectionState {
        case .connecting:
            webRTCConnectingOverlay
        case .connected:
            webRTCVideoContent
        case .failed(let message):
            webRTCErrorOverlay(message: message)
        case .disconnected:
            webRTCDisconnectedOverlay
        }
    }

    private var webRTCConnectingOverlay: some View {
        ZStack {
            snapshotBackdrop
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Connecting to \(device.name)…")
                    .font(.system(size: Constants.UI.bodySize))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connecting to \(device.name)"))
    }

    @ViewBuilder
    private var webRTCVideoContent: some View {
        #if canImport(WebRTC)
        WebRTCVideoView(videoTrack: viewModel.videoTrack)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("Live video from \(device.name)"))
        #else
        Color.black
        #endif
    }

    private func webRTCErrorOverlay(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text(message)
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            HStack(spacing: 30) {
                Button("Retry") {
                    Task { await viewModel.retry() }
                }
                .accessibilityLabel(Text("Retry stream"))
                .accessibilityHint(Text("Double-click to retry connecting to the camera"))

                Button("Back") {
                    dismiss()
                }
                .accessibilityLabel(Text("Go back"))
                .accessibilityHint(Text("Double-click to return to the previous screen"))
            }
            .font(.system(size: Constants.UI.bodySize))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var webRTCDisconnectedOverlay: some View {
        ZStack {
            snapshotBackdrop
            VStack(spacing: 24) {
                Image(systemName: "video.slash")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)

                Text("Stream ended")
                    .font(.system(size: Constants.UI.titleSize, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 30) {
                    Button("Restart") {
                        Task { await viewModel.retry() }
                    }
                    .accessibilityLabel(Text("Restart stream"))

                    Button("Back") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("Go back"))
                }
                .font(.system(size: Constants.UI.bodySize))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Snapshot Backdrop

    @ViewBuilder
    private var snapshotBackdrop: some View {
        #if canImport(UIKit)
        if let snapshotData,
           let uiImage = UIImage(data: snapshotData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(Color.black.opacity(0.6))
        } else {
            Color.black
        }
        #elseif canImport(AppKit)
        if let snapshotData,
           let nsImage = NSImage(data: snapshotData) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(Color.black.opacity(0.6))
        } else {
            Color.black
        }
        #else
        Color.black
        #endif
    }

    // MARK: - Device Name Overlay

    private var deviceNameOverlay: some View {
        Text(device.name)
            .font(.system(size: Constants.UI.titleSize, weight: .semibold))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 2)
            .padding(Constants.UI.cardPadding)
            .accessibilityHidden(true)
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(device.name)…")
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connecting to \(device.name)"))
    }

    // MARK: - Error Overlay

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text(message)
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            HStack(spacing: 30) {
                Button("Retry") {
                    Task { await viewModel.retry() }
                }
                .accessibilityLabel(Text("Retry stream"))
                .accessibilityHint(Text("Double-click to retry connecting to the camera"))

                Button("Back") {
                    dismiss()
                }
                .accessibilityLabel(Text("Go back"))
                .accessibilityHint(Text("Double-click to return to the previous screen"))
            }
            .font(.system(size: Constants.UI.bodySize))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
