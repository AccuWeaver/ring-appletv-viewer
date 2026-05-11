import SwiftUI

/// Pill-shaped camera switcher button at the top of the player overlay.
///
/// Displays the active camera's name alongside a chevron indicator and, on
/// selection, presents the camera picker via
/// ``PlayerControlsViewModel/isCameraPickerPresented``. The view hides itself
/// when there are fewer than two available devices (Requirement 2.7), so
/// single-camera accounts never see a switcher they can't use.
///
/// Focus binding is left to the parent overlay: `CameraSwitcherView` is a
/// SwiftUI `Button`, which the overlay can attach a `.focused($focus, equals:
/// .cameraSwitcher)` modifier to when composing the full layout (task 4.3).
struct CameraSwitcherView: View {
    @ObservedObject var viewModel: PlayerControlsViewModel

    var body: some View {
        if viewModel.availableDevices.count <= 1 {
            // Requirement 2.7: with one (or zero) devices there is nothing to
            // switch to, so the control is fully removed from the hierarchy.
            // Returning `EmptyView` keeps the focus engine from reserving a
            // slot for an invisible control.
            EmptyView()
        } else {
            Button(action: presentPicker) {
                HStack(spacing: 12) {
                    Text(viewModel.activeDevice.name)
                        .font(.system(size: Constants.UI.bodySize, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: Constants.UI.bodySize - 6, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(Color.black.opacity(0.55))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Camera: \(viewModel.activeDevice.name)"))
            .accessibilityHint(Text("Double-click to choose a different camera"))
        }
    }

    /// Resets the inactivity timer for the interaction (Requirement 1.4) and
    /// flips the picker presentation flag the overlay observes. The camera
    /// picker view itself is responsible for pausing the timer while it's
    /// open (task 3.2).
    private func presentPicker() {
        viewModel.resetInactivityTimer()
        viewModel.isCameraPickerPresented = true
    }
}
