import SwiftUI

/// Speaker button that toggles audio between muted and unmuted states.
///
/// Renders `speaker.wave.2.fill` when audio is active and `speaker.slash.fill`
/// when muted, reflecting ``PlayerControlsViewModel/isMuted`` (Requirement 5.1).
/// Selecting the button flips the state via ``PlayerControlsViewModel/toggleMute()``
/// (Requirements 5.2, 5.3). Positioning at the bottom-right of the overlay
/// (Requirement 7.5) is the parent overlay's responsibility — this view only
/// renders the button and binds its focus.
struct MuteToggleView: View {
    @ObservedObject var viewModel: PlayerControlsViewModel
    var focused: FocusState<ControlFocus?>.Binding

    var body: some View {
        Button {
            viewModel.toggleMute()
        } label: {
            Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .focused(focused, equals: .muteToggle)
        .accessibilityLabel(viewModel.isMuted ? "Unmute audio" : "Mute audio")
        .accessibilityHint(
            Text(viewModel.isMuted
                ? "Double-click to unmute the camera audio"
                : "Double-click to mute the camera audio"
            )
        )
    }
}
