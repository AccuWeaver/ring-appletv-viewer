import SwiftUI

/// Transport controls row (skip-back, play/pause, skip-forward) at the center
/// of the player overlay.
///
/// The view is intentionally dumb: it reads state from the shared
/// ``PlayerControlsViewModel`` and delegates every button press back to the
/// view model, so overlay-wide concerns like the inactivity timer and
/// live-edge handling live in one place.
///
/// Focus is coordinated by the parent overlay through a `@FocusState` binding
/// typed on ``ControlFocus``. Each button attaches
/// `.focused($focused, equals: .skipBack / .playPause / .skipForward)` so
/// swipes between rows (task 4.3) can move focus into the middle row and
/// horizontal swipes can move between these three buttons.
struct PlaybackControlsView: View {
    @ObservedObject var viewModel: PlayerControlsViewModel

    /// Focus binding owned by the parent overlay. The three transport buttons
    /// register themselves against ``ControlFocus/skipBack``,
    /// ``ControlFocus/playPause``, and ``ControlFocus/skipForward`` so the
    /// overlay can set initial focus on play/pause (Requirement 6.1) and
    /// Siri Remote navigation can shuttle between them.
    @FocusState.Binding var focused: ControlFocus?

    var body: some View {
        HStack(spacing: 48) {
            Button(action: skipBack) {
                Image(systemName: "gobackward.10")
                    .font(.system(size: Constants.UI.titleSize, weight: .semibold))
                    .frame(
                        minWidth: Constants.UI.minimumFocusSize,
                        minHeight: Constants.UI.minimumFocusSize
                    )
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .skipBack)
            .accessibilityLabel(Text("Skip back"))
            .accessibilityHint(Text("Double-click to jump to the previous event"))

            Button(action: togglePlayPause) {
                Image(systemName: viewModel.playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: Constants.UI.largeTitleSize, weight: .bold))
                    .frame(
                        minWidth: Constants.UI.minimumFocusSize,
                        minHeight: Constants.UI.minimumFocusSize
                    )
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .playPause)
            .accessibilityLabel(
                Text(viewModel.playerViewModel.isPlaying ? "Pause" : "Play")
            )
            .accessibilityHint(
                Text(viewModel.playerViewModel.isPlaying
                    ? "Double-click to pause playback"
                    : "Double-click to resume playback"
                )
            )

            Button(action: skipForward) {
                Image(systemName: "goforward.10")
                    .font(.system(size: Constants.UI.titleSize, weight: .semibold))
                    .frame(
                        minWidth: Constants.UI.minimumFocusSize,
                        minHeight: Constants.UI.minimumFocusSize
                    )
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            // Requirement 4.6: at the live edge the skip-forward button is
            // visually dimmed and non-interactive. `.disabled(true)` also
            // removes it from the focus engine, so swipes on the middle row
            // skip past it to the live button (when visible).
            .opacity(viewModel.isAtLiveEdge ? 0.5 : 1.0)
            .disabled(viewModel.isAtLiveEdge)
            .focused($focused, equals: .skipForward)
            .accessibilityLabel(Text("Skip forward"))
            .accessibilityHint(
                Text(viewModel.isAtLiveEdge
                    ? "Unavailable at live edge"
                    : "Double-click to jump to the next event"
                )
            )
        }
    }

    // MARK: - Actions

    /// Delegates to ``PlayerControlsViewModel/skipBack()``. The view model is
    /// responsible for bounds clamping and resetting the inactivity timer.
    private func skipBack() {
        viewModel.skipBack()
    }

    /// Delegates to ``PlayerControlsViewModel/togglePlayPause()``. Button
    /// visuals update reactively through the `@ObservedObject` binding on
    /// ``PlayerControlsViewModel/playerViewModel``.
    private func togglePlayPause() {
        viewModel.togglePlayPause()
    }

    /// Delegates to ``PlayerControlsViewModel/skipForward()``. The no-op at
    /// the live edge is enforced by the view model as well; the `.disabled`
    /// modifier above prevents the button from firing in that state, so this
    /// is belt-and-braces.
    private func skipForward() {
        viewModel.skipForward()
    }
}
