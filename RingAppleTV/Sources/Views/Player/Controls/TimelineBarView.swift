import SwiftUI

/// Horizontal timeline strip at the bottom of the player overlay.
///
/// Renders an event-marker dot for each item in
/// ``PlayerControlsViewModel/events``, a distinct playhead indicator at the
/// current position, and a "Live" label pinned to the right edge when the
/// stream is at the real-time edge.
///
/// Scrubbing is driven by left/right directional input on the Siri Remote
/// trackpad. The view is focusable so it can receive `.onMoveCommand` events
/// on tvOS; a left swipe calls ``PlayerControlsViewModel/skipBack()`` and a
/// right swipe calls ``PlayerControlsViewModel/skipForward()``. Before each
/// skip we pause the inactivity timer so the overlay can't auto-hide mid
/// scrub (Requirement 3.8); the view model's skip methods then call
/// `resetInactivityTimer()` on completion, which reschedules the countdown
/// once the movement has landed.
///
/// Layout responsibilities (positions, padding, width) come from the parent
/// ``PlayerControlsOverlay`` — this view fills the width it's given and draws
/// the bar with a small internal horizontal inset so the first/last dots
/// aren't clipped.
struct TimelineBarView: View {
    @ObservedObject var viewModel: PlayerControlsViewModel
    @FocusState private var isFocused: Bool

    // MARK: - Layout

    /// Horizontal inset so the earliest/latest event dots don't sit flush
    /// against the edges of the bar.
    private let horizontalInset: CGFloat = 12

    /// Width reserved on the right for the "Live" label so the scrub region
    /// stops short of it.
    private let liveLabelWidth: CGFloat = 80

    /// Visual dimensions for the thin track and the markers/playhead drawn
    /// on top of it.
    private let trackHeight: CGFloat = 4
    private let eventMarkerDiameter: CGFloat = 14
    private let playheadDiameter: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - horizontalInset * 2 - liveLabelWidth, 0)

            ZStack(alignment: .leading) {
                // Base track — a full-width line the markers sit on.
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.white.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.trailing, liveLabelWidth)
                    .padding(.horizontal, horizontalInset)

                // Event markers, positioned proportionally along the scrub
                // region. With 0 or 1 events the math below degenerates
                // safely thanks to `eventX(for:)`.
                ForEach(Array(viewModel.events.enumerated()), id: \.element.id) { index, event in
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: eventMarkerDiameter, height: eventMarkerDiameter)
                        .position(
                            x: eventX(for: index, width: availableWidth),
                            y: proxy.size.height / 2
                        )
                        .accessibilityHidden(true)
                        // The accessible element is handled by the bar itself
                        // (see `.accessibilityLabel` below) so VoiceOver
                        // announces the timeline as a single scrubbable
                        // control rather than reading every dot individually.
                        .help(event.eventType.displayName)
                }

                // Playhead — either on top of the current event or pinned to
                // the right of the scrub region when at live edge.
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .frame(width: playheadDiameter, height: playheadDiameter)
                    .position(
                        x: playheadX(width: availableWidth),
                        y: proxy.size.height / 2
                    )
                    .accessibilityHidden(true)

                // "Live" label on the right; only shown while at the live
                // edge (Requirement 3.2). When scrubbed into history the
                // focusable Live *button* is rendered by the overlay
                // separately.
                if viewModel.isAtLiveEdge {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("Live")
                            .font(.system(size: Constants.UI.captionSize, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: liveLabelWidth, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, horizontalInset)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: max(playheadDiameter, eventMarkerDiameter) + 8)
        #if os(tvOS)
        // `.focusable()` is required so `.onMoveCommand` receives Siri Remote
        // trackpad swipe events on tvOS. The `onFocusChange` callback keeps
        // the overlay visible while the user is scrubbing.
        .focusable()
        .focused($isFocused)
        .onChange(of: isFocused) { newValue in
            if newValue {
                viewModel.pauseInactivityTimer()
            } else {
                viewModel.resumeInactivityTimer()
            }
        }
        .onMoveCommand(perform: handleMoveCommand(_:))
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Event timeline"))
        .accessibilityValue(Text(accessibilityValueText))
        .accessibilityHint(Text("Swipe left or right to scrub through event history"))
        .accessibilityAddTraits(.isSummaryElement)
    }

    // MARK: - Position math

    /// X coordinate for the event marker at `index` along the scrub region.
    ///
    /// - Parameters:
    ///   - index: Event index; valid range `0..<events.count`.
    ///   - width: Width of the scrub region (already excludes the left/right
    ///     insets and the reserved Live-label area).
    private func eventX(for index: Int, width: CGFloat) -> CGFloat {
        let count = viewModel.events.count
        guard count > 0 else { return horizontalInset }
        let fraction: CGFloat
        if count == 1 {
            // Place a single event at the centre of the scrub region so it
            // reads as "one event in the past" rather than pinned to a corner.
            fraction = 0.5
        } else {
            fraction = CGFloat(index) / CGFloat(count - 1)
        }
        return horizontalInset + fraction * width
    }

    /// X coordinate for the playhead.
    ///
    /// When at the live edge the playhead sits at the right of the scrub
    /// region, just before the "Live" label. Otherwise it aligns with the
    /// current event marker.
    private func playheadX(width: CGFloat) -> CGFloat {
        if viewModel.isAtLiveEdge {
            return horizontalInset + width
        }
        guard let idx = viewModel.currentEventIndex,
              viewModel.events.indices.contains(idx) else {
            return horizontalInset + width
        }
        return eventX(for: idx, width: width)
    }

    // MARK: - Scrubbing

    #if os(tvOS)
    /// Handles left/right directional input from the Siri Remote trackpad.
    ///
    /// Up/down are intentionally ignored so the focus engine can move between
    /// the timeline and the rows above/below it (the overlay's focus sections
    /// handle vertical navigation).
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            viewModel.pauseInactivityTimer()
            viewModel.skipBack()
        case .right:
            viewModel.pauseInactivityTimer()
            viewModel.skipForward()
        default:
            // `.up` / `.down` fall through to the focus engine.
            break
        }
    }
    #endif

    // MARK: - Accessibility

    /// Human-readable description of the current playhead position for
    /// VoiceOver. Kept compact because tvOS VoiceOver cuts off long values.
    private var accessibilityValueText: String {
        if viewModel.isAtLiveEdge {
            return "At live edge"
        }
        guard let idx = viewModel.currentEventIndex,
              viewModel.events.indices.contains(idx) else {
            return "No current event"
        }
        let position = idx + 1
        return "Event \(position) of \(viewModel.events.count)"
    }
}
