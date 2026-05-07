#if canImport(WebRTC)
import SwiftUI
import WebRTC

// MARK: - WebRTCVideoView

/// SwiftUI wrapper for `RTCMTLVideoView` (Metal-backed WebRTC video renderer).
///
/// Renders an incoming `RTCVideoTrack` full-screen with aspect-fit scaling (FR-4.1, FR-4.4).
/// Automatically attaches/detaches the video track as it changes, ensuring proper cleanup
/// when the track becomes nil or is replaced.
struct WebRTCVideoView: UIViewRepresentable {

    /// The video track to render. Pass `nil` to detach and show a black frame.
    let videoTrack: RTCVideoTrack?

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.contentMode = .scaleAspectFit
        videoView.backgroundColor = .black
        return videoView
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let previousTrack = context.coordinator.currentTrack

        // Detach the previous track if it differs from the new one
        if let previous = previousTrack, previous !== videoTrack {
            previous.remove(uiView)
        }

        // Attach the new track if it's non-nil and different from the previous
        if let track = videoTrack, track !== previousTrack {
            track.add(uiView)
        }

        // Update the coordinator's reference
        context.coordinator.currentTrack = videoTrack
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        // Detach any remaining track on teardown
        coordinator.currentTrack?.remove(uiView)
        coordinator.currentTrack = nil
    }

    // MARK: - Coordinator

    /// Tracks the previously attached `RTCVideoTrack` so we can properly detach it
    /// when the track changes or the view is torn down.
    final class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}
#endif
