import Foundation

/// Identifies individual focusable controls within the player overlay.
///
/// Used with SwiftUI's `@FocusState` to drive Siri Remote navigation between
/// the camera switcher, playback controls, live button, and mute toggle.
enum ControlFocus: Hashable {
    case cameraSwitcher
    case skipBack
    case playPause
    case skipForward
    case muteToggle
    case liveButton
}
