import SwiftUI

/// Focusable pill-shaped button that jumps playback back to the real-time
/// live edge for the active Ring camera.
///
/// Per Requirement 3.6 the button is only shown when the stream is *not*
/// at the live edge. When the view model reports ``PlayerControlsViewModel/isAtLiveEdge``
/// the body collapses to ``EmptyView`` so the button doesn't occupy focus
/// or layout space. When visible, selecting it dispatches
/// ``PlayerControlsViewModel/jumpToLive()`` (Requirement 3.7) which resumes
/// the live stream and clears the timeline playhead.
///
/// The parent view owns the overlay-wide ``FocusState`` and passes its
/// binding in so this view can plug into shared focus routing via
/// `.focused($focused, equals: .liveButton)`.
struct LiveButton: View {
    @ObservedObject var viewModel: PlayerControlsViewModel
    var focused: FocusState<ControlFocus?>.Binding

    var body: some View {
        if viewModel.isAtLiveEdge {
            EmptyView()
        } else {
            Button {
                viewModel.jumpToLive()
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                    Text("Live")
                        .font(.system(size: Constants.UI.bodySize, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(Color.white.opacity(0.15))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .focused(focused, equals: .liveButton)
            .accessibilityLabel(Text("Jump to live"))
            .accessibilityHint(Text("Double-click to resume the live stream"))
        }
    }
}
