import Foundation

/// Namespace for shared constants used by the player controls overlay.
///
/// Declared as a case-less enum so it acts as a pure namespace that cannot be instantiated.
enum PlayerControlsConstants {
    /// Duration of inactivity after which the controls overlay auto-hides.
    static let inactivityTimeout: TimeInterval = 5.0

    /// Duration of the overlay fade-in / fade-out animation.
    static let fadeAnimationDuration: TimeInterval = 0.3
}
