import SwiftUI

/// Modal picker presented from the ``CameraSwitcherView``.
///
/// Renders the list of currently online Ring cameras (as published on
/// ``PlayerControlsViewModel/availableDevices``) with a checkmark beside the
/// active device. Selecting a row hands off to
/// ``PlayerControlsViewModel/selectCamera(_:)``, which tears down the current
/// stream and starts a new one. Dismissing without a selection (Menu button
/// on the Siri Remote) leaves state untouched and returns the user to the
/// still-visible overlay (Requirement 2.6).
///
/// While the picker is on screen, the inactivity auto-hide timer is paused
/// via `onAppear`/`onDisappear` so the overlay doesn't disappear beneath the
/// modal (Requirement 3.8 generalises "pause during user focus"; the design
/// error-handling table calls this out explicitly for the picker).
struct CameraPickerView: View {
    @ObservedObject var viewModel: PlayerControlsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a camera")
                .font(.system(size: Constants.UI.titleSize, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, Constants.UI.cardPadding)
                .padding(.top, Constants.UI.cardPadding)
                .padding(.bottom, Constants.UI.cardPadding / 2)
                .accessibilityAddTraits(.isHeader)

            Divider()
                .background(Color.white.opacity(0.15))

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(viewModel.availableDevices) { device in
                        deviceRow(for: device)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: 720)
        .background(
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                .fill(Color.black.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(Constants.UI.cardPadding)
        .onAppear {
            // Pause the overlay's auto-hide while the picker is visible.
            viewModel.pauseInactivityTimer()
        }
        .onDisappear {
            // Resume regardless of how the picker went away (selection or
            // Menu-press dismiss). `resumeInactivityTimer` is a no-op if the
            // overlay is no longer visible — e.g. after `selectCamera`
            // hides it — so this is safe in both paths.
            viewModel.resumeInactivityTimer()
        }
    }

    // MARK: - Rows

    /// Renders a single focusable row for `device`. The active device gets a
    /// trailing checkmark; the non-active devices get a trailing dot so the
    /// layout width is consistent and the list reads well with VoiceOver.
    private func deviceRow(for device: RingDevice) -> some View {
        let isActive = device.id == viewModel.activeDevice.id
        return Button {
            select(device)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "video.fill")
                    .font(.system(size: Constants.UI.bodySize - 6))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 32)

                Text(device.name)
                    .font(.system(size: Constants.UI.bodySize, weight: isActive ? .semibold : .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 16)

                Image(systemName: isActive ? "checkmark" : "circle")
                    .font(.system(size: Constants.UI.bodySize - 6, weight: .semibold))
                    .foregroundColor(isActive ? .white : .white.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Constants.UI.cardPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(device.name))
        .accessibilityHint(Text(isActive
            ? "Currently selected camera"
            : "Double-click to switch to this camera"
        ))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Actions

    /// Hands off to the view model to perform the camera switch. Flipping
    /// ``PlayerControlsViewModel/isCameraPickerPresented`` closes the sheet
    /// immediately so the new camera's loading state appears without the
    /// picker lingering on top. `selectCamera` itself stops the old stream,
    /// starts the new one, re-applies the mute state, and hides the overlay.
    private func select(_ device: RingDevice) {
        viewModel.isCameraPickerPresented = false
        Task {
            await viewModel.selectCamera(device)
        }
    }
}
