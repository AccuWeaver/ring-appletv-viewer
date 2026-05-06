import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// A lightweight HLS video player that wraps `AVPlayer` + `AVPlayerLayer` directly.
///
/// Used as the simulator/dev fallback when real WebRTC streaming isn't available.
/// Unlike AVKit's `VideoPlayer`, this wrapper does NOT capture focus or the Menu
/// button — so the parent view's `.onExitCommand` handler can receive the Menu
/// press and dismiss the player.
struct HLSPlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        let player = AVPlayer(url: url)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        player.play()
        context.coordinator.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // No-op — the player is configured once in makeUIView.
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        uiView.playerLayer.player = nil
        coordinator.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var player: AVPlayer?
    }
}

/// A UIView backed by an AVPlayerLayer. Not focusable, so Menu button passes
/// through to the parent view's onExitCommand handler.
final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    #if os(tvOS)
    // Ensure this view doesn't become the focused item — prevents it from
    // swallowing remote button presses that should go to the parent.
    override var canBecomeFocused: Bool { false }
    #endif
}
