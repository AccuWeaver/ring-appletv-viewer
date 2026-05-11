import SwiftUI

/// Container view that composes every player control into a single
/// Netflix-style overlay layered on top of the video content in ``PlayerView``.
///
/// This is the composition/layout pass established by task 4.1 of the
/// `player-controls` spec. It wires the individual subviews into the
/// `ZStack` described by the design mocks and exposes a single
/// ``FocusState`` that will later be threaded into the tvOS focus engine:
///
/// - ``CameraSwitcherView`` pinned top-center
/// - ``PlaybackControlsView`` centered, with ``LiveButton`` beside it when
///   the stream has been scrubbed off the live edge (Requirement 3.6)
/// - ``TimelineBarView`` pinned to the bottom, spanning the full width with
///   horizontal padding (Requirement 7.4)
/// - ``MuteToggleView`` pinned to the bottom-right via an alignment overlay
///   (Requirement 7.5)
/// - ``CameraPickerView`` presented as a sheet bound to
///   ``PlayerControlsViewModel/isCameraPickerPresented``
///
/// The gradient backdrop darkens only the top and bottom edges of the
/// frame (Requirement 7.1) so the center of the video stays visible behind
/// the transport controls.
///
/// Scope note: this task also covers the fade-in / fade-out visibility
/// animation established by task 4.2, plus the focus section routing and
/// initial-focus biasing of task 4.3. Per-interaction inactivity-timer
/// resets (task 4.4) are handled inside the view-model action methods
/// (`togglePlayPause`, `skipBack`, `skipForward`, `jumpToLive`,
/// `toggleMute`) so that every entry point — including the hardware
/// Play/Pause key that bypasses the UI — honours Requirement 1.4. The
/// camera-switcher pill (which only flips a sheet flag and does not
/// delegate to a view-model action) and the timeline-bar scrub gesture
/// reset the timer explicitly at their call sites.
struct PlayerControlsOverlay: View {

    // MARK: - Dependencies

    /// Shared state for the overlay. Each subview observes this model
    /// directly so button taps, mute toggling, timeline scrubbing, and
    /// camera selection all flow through a single source of truth.
    @ObservedObject var viewModel: PlayerControlsViewModel

    // MARK: - Focus

    /// Focus coordinator for Siri Remote navigation between the overlay's
    /// focusable controls. The bindings are forwarded into the subviews
    /// that need them (``PlaybackControlsView``, ``LiveButton``,
    /// ``MuteToggleView``); ``CameraSwitcherView`` and ``TimelineBarView``
    /// manage their own focus internally and don't require the shared
    /// binding yet.
    ///
    /// The overlay explicitly writes ``ControlFocus/playPause`` into this
    /// state when it becomes visible (Requirement 6.1) so play/pause is
    /// the initial focus target regardless of the focus engine's default
    /// heuristics.
    @FocusState private var focusedControl: ControlFocus?

    /// Namespace that scopes ``SwiftUI/View/prefersDefaultFocus(_:in:)``
    /// hints inside the overlay. Applied to the outer container via
    /// `.focusScope(_:)` so the focus engine knows which scope the
    /// preference belongs to; the play/pause row advertises itself as the
    /// preferred default within that scope.
    ///
    /// Explicitly setting `focusedControl = .playPause` in `onAppear` is
    /// the primary mechanism for biasing initial focus; the
    /// `prefersDefaultFocus` hint acts as a fallback for the focus engine
    /// on re-entry (for example, when the camera picker sheet dismisses).
    @Namespace private var overlayNamespace

    // MARK: - Body

    var body: some View {
        // Requirement 1.6 / 6.6: when the overlay is hidden, the entire
        // subtree is removed from the view hierarchy so no focusable
        // elements remain to intercept Siri Remote directional input. A
        // bare `if` inside a `Group` gives SwiftUI a stable identity to
        // animate between (content absent) and (content present).
        //
        // Requirement 7.6 / 1.1 / 1.2 / 1.5: the cross-fade between those
        // two states uses `.transition(.opacity)` on the inner content,
        // driven by `.animation(...)` bound to
        // `viewModel.isOverlayVisible` on the outer `Group`. That pairing
        // produces the 0.3 s ease-in-out fade described by the spec for
        // every show / hide transition — user-initiated (task 4.2) and
        // timer-driven (task 2.2).
        Group {
            if viewModel.isOverlayVisible {
                overlayContent
                    .transition(.opacity)
            }
        }
        .animation(
            .easeInOut(duration: PlayerControlsConstants.fadeAnimationDuration),
            value: viewModel.isOverlayVisible
        )
    }

    /// The composed overlay itself. Factored out of ``body`` so the
    /// `if`-based conditional above stays readable and the transition /
    /// animation wiring is not tangled with layout code.
    private var overlayContent: some View {
        ZStack {
            // Requirement 7.1: semi-transparent gradient background that
            // darkens the top and bottom edges of the video while leaving
            // the center unobscured. `.allowsHitTesting(false)` makes the
            // gradient decorative only so taps fall through to either a
            // button or (eventually) the overlay toggle gesture on
            // `PlayerView`.
            gradientBackdrop
                .allowsHitTesting(false)

            // Top / middle / bottom stack for the primary controls. The
            // `Spacer`s between rows let the middle row float vertically
            // centered regardless of the camera switcher's presence or the
            // timeline bar's height.
            //
            // Each row is wrapped in a `.focusSection()` so the tvOS focus
            // engine treats it as a horizontal group (Requirement 6.2,
            // 6.3, 6.4): vertical swipes on the Siri Remote trackpad move
            // focus *between* rows, while horizontal swipes move *within*
            // the currently focused row.
            VStack(spacing: 0) {
                CameraSwitcherView(viewModel: viewModel)
                    .padding(.top, Constants.UI.cardPadding)
                    .focusSection()

                Spacer()

                // Middle row: transport controls, with the live button
                // beside them when the stream has been scrubbed off live.
                // `LiveButton` already collapses to `EmptyView` at the
                // live edge, so the `HStack` width adjusts automatically.
                //
                // `.prefersDefaultFocus(in: overlayNamespace)` biases the
                // focus engine toward this row when the overlay re-enters
                // the hierarchy (Requirement 6.1); the explicit
                // `focusedControl = .playPause` assignment in `onAppear`
                // below is the primary mechanism, with this hint as a
                // backstop for scope re-evaluations.
                HStack(spacing: 32) {
                    PlaybackControlsView(
                        viewModel: viewModel,
                        focused: $focusedControl
                    )
                    LiveButton(
                        viewModel: viewModel,
                        focused: $focusedControl
                    )
                }
                .focusSection()
                .prefersDefaultFocus(in: overlayNamespace)

                Spacer()

                // Requirement 7.4: bottom-spanning timeline with horizontal
                // padding so the first/last event markers don't touch the
                // screen edges. The timeline manages its own focus (it is
                // a single focusable element that handles directional
                // input internally) but is still wrapped in a
                // `.focusSection()` so vertical swipes from the middle row
                // can land on it as a distinct focus target rather than
                // jumping straight to the mute toggle.
                TimelineBarView(viewModel: viewModel)
                    .padding(.horizontal, Constants.UI.cardPadding)
                    .padding(.bottom, Constants.UI.cardPadding)
                    .focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Requirement 7.5: mute toggle pinned to the bottom-right via an
        // alignment overlay, keeping it out of the vertical stack's flow so
        // it doesn't shift when the timeline bar changes height. It lives
        // in its own focus section so a swipe-right from the middle row's
        // last element moves focus to it (and swipe-left returns).
        .overlay(alignment: .bottomTrailing) {
            MuteToggleView(
                viewModel: viewModel,
                focused: $focusedControl
            )
            .padding(Constants.UI.cardPadding)
            .focusSection()
        }
        // Scope the `prefersDefaultFocus` hint applied to the playback row
        // above. `.focusScope(_:)` must wrap every view that participates
        // in the scope, so it's attached at the outer container level.
        .focusScope(overlayNamespace)
        // Requirement 6.1: when the overlay becomes visible, play/pause
        // receives initial focus. The overlay is re-added to the view
        // hierarchy each time it appears (see the `Group { if … }` in
        // `body`), so `onAppear` fires on every show and the explicit
        // assignment below guarantees the bias even if the focus engine's
        // default resolution would pick a different element.
        .onAppear {
            focusedControl = .playPause
        }
        // Requirements 2.2–2.6: tapping the camera switcher sets
        // `isCameraPickerPresented = true`; the sheet below observes that
        // flag and presents `CameraPickerView`. Dismissing the sheet without
        // a selection leaves state untouched and returns the user to the
        // still-visible overlay.
        .sheet(isPresented: $viewModel.isCameraPickerPresented) {
            CameraPickerView(viewModel: viewModel)
        }
    }

    // MARK: - Backdrop

    /// Two stacked linear gradients — one fading down from black at the top
    /// edge and one fading up from black at the bottom edge — sandwiched
    /// around a transparent center band. Drawn as a `VStack` so the middle
    /// `Color.clear` region has a deterministic height (`minLength: 0`) even
    /// on very short frames.
    private var gradientBackdrop: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.65),
                    Color.black.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)

            Color.clear
                .frame(maxHeight: .infinity)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.75)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 260)
        }
    }
}
