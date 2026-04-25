import SwiftUI
import AVKit

/// Full-screen video player for Ring live streams and event playback.
/// Integrates AVPlayer for HLS, with loading/error overlays and Siri Remote controls.
struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let device: RingDevice

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .idle:
                Color.clear.onAppear {
                    Task { await viewModel.requestStream(for: device.id) }
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
        .navigationBarHidden(true)
        .ignoresSafeArea()
    }

    // MARK: - Player Content

    private func playerContent(session: StreamSession) -> some View {
        ZStack(alignment: .topLeading) {
            // AVPlayer
            VideoPlayer(player: AVPlayer(url: session.hlsURL))
                .ignoresSafeArea()
                .accessibilityLabel(Text("Live stream from \(device.description)"))
                .accessibilityHint(Text("Press Select to play or pause. Press Menu to go back."))

            // Device name overlay
            deviceNameOverlay
        }
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Device Name Overlay

    private var deviceNameOverlay: some View {
        Text(device.description)
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
            Text("Connecting to \(device.description)…")
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connecting to \(device.description)"))
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
