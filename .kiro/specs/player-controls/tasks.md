# Implementation Plan: Player Controls

## Overview

This plan adds a Netflix-style playback controls overlay to the RingAppleTV `PlayerView`. Tasks are ordered so foundation types and the view model come first, then subviews, then overlay assembly and `PlayerView` integration, and finally tests. Each task references the requirements it satisfies.

## Tasks

- [x] 1. Foundation types and constants
  - [x] 1.1 Create `ControlFocus` enum
    - Add `RingAppleTV/Sources/Views/Player/Controls/ControlFocus.swift` with cases: `cameraSwitcher`, `skipBack`, `playPause`, `skipForward`, `muteToggle`, `liveButton`
    - Conform to `Hashable`
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [x] 1.2 Create `TimelinePosition` value type
    - Add `RingAppleTV/Sources/Views/Player/Controls/TimelinePosition.swift`
    - Properties: `eventIndex: Int?` (nil = live edge), `events: [RingEvent]`
    - Computed: `isAtLiveEdge`, `currentEvent`
    - Methods: `movingBack()`, `movingForward()`, static `live(events:)`
    - Bounds behavior: moving back from earliest clamps at earliest; moving forward from live edge stays at live; moving forward from last event clamps at live edge
    - _Requirements: 3.3, 3.4, 4.4, 4.5, 4.6_

  - [x] 1.3 Create `PlayerControlsConstants`
    - Add `RingAppleTV/Sources/Views/Player/Controls/PlayerControlsConstants.swift`
    - Static constants: `inactivityTimeout: TimeInterval = 5.0`, `fadeAnimationDuration: TimeInterval = 0.3`
    - _Requirements: 1.3, 1.5, 7.6_

- [x] 2. PlayerControlsViewModel
  - [x] 2.1 Create `PlayerControlsViewModel` skeleton
    - Add `RingAppleTV/Sources/ViewModels/PlayerControlsViewModel.swift`
    - `@MainActor final class PlayerControlsViewModel: ObservableObject`
    - `@Published` properties for `isOverlayVisible`, `isMuted`, `isAtLiveEdge`, `events`, `currentEventIndex`, `availableDevices`, `activeDevice`, `isCameraPickerPresented`
    - Init accepting `playerViewModel: PlayerViewModel`, `deviceService: DeviceService`, `eventService: EventService`, `activeDevice: RingDevice`
    - _Requirements: 2.1, 2.2, 3.1, 3.2, 5.1_

  - [x] 2.2 Implement overlay visibility and inactivity timer
    - Methods: `toggleOverlay()`, `showOverlay()`, `hideOverlay()`, `resetInactivityTimer()`, `pauseInactivityTimer()`, `resumeInactivityTimer()`
    - Use `Timer.scheduledTimer` with `inactivityTimeout`; invalidate on hide, pause, and reset
    - Timer runs only while the overlay is visible
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 3.8_

  - [x] 2.3 Implement playback control actions
    - `togglePlayPause()` delegates to `playerViewModel.togglePlayPause()` and calls `resetInactivityTimer()`
    - `skipBack()` moves `currentEventIndex` backward via `TimelinePosition.movingBack()`; loads recorded event on transition away from live
    - `skipForward()` moves forward via `TimelinePosition.movingForward()`; no-op at live edge
    - `jumpToLive()` calls `playerViewModel.requestStream(for:powerSource:)` with the active device and clears `currentEventIndex`
    - _Requirements: 3.5, 3.7, 4.2, 4.3, 4.4, 4.5, 4.6_

  - [x] 2.4 Implement mute toggle
    - `toggleMute()` inverts `isMuted` and applies the state to the current stream via `StreamSessionManager` (audio track enabled/disabled) when WebRTC is active; for mock/HLS fallback, drive an `AVPlayer.isMuted` binding surfaced through `PlayerViewModel`
    - Mute state survives across `selectCamera` calls
    - _Requirements: 5.1, 5.2, 5.3, 5.4_

  - [x] 2.5 Implement camera loading and switching
    - `loadAvailableDevices()` fetches online devices via `DeviceService.fetchDevices()` and assigns to `availableDevices`
    - `selectCamera(_:)` stops the current stream via `playerViewModel.stopStream()`, updates `activeDevice`, calls `playerViewModel.requestStream(for:powerSource:)`, re-applies current mute state, then calls `hideOverlay()`
    - `loadEvents()` fetches recent events via `EventService.fetchEvents(for:)` for the active device and populates `events`
    - _Requirements: 2.2, 2.3, 2.4, 2.5, 3.1_

- [x] 3. Subviews
  - [x] 3.1 Create `CameraSwitcherView`
    - Add `RingAppleTV/Sources/Views/Player/Controls/CameraSwitcherView.swift`
    - Pill-shaped button showing active camera name + chevron icon
    - Hidden when `availableDevices.count <= 1`
    - Focusable; on select, sets `viewModel.isCameraPickerPresented = true`
    - _Requirements: 2.1, 2.2, 2.7, 7.2_

  - [x] 3.2 Create `CameraPickerView`
    - Add `RingAppleTV/Sources/Views/Player/Controls/CameraPickerView.swift`
    - Modal list of online devices from `viewModel.availableDevices`
    - Selecting a device calls `viewModel.selectCamera(_:)`
    - Dismiss without selection leaves state unchanged and returns to overlay
    - While presented, pauses the inactivity timer; on dismiss, resumes it
    - _Requirements: 2.2, 2.3, 2.4, 2.5, 2.6, 3.8_

  - [x] 3.3 Create `TimelineBarView`
    - Add `RingAppleTV/Sources/Views/Player/Controls/TimelineBarView.swift`
    - Horizontal bar rendering an event marker dot for each item in `viewModel.events`
    - Playhead indicator at the position corresponding to `currentEventIndex` (or far right when at live edge)
    - "Live" label visible when `isAtLiveEdge`
    - Swipe left/right on the Siri Remote trackpad scrubs through event markers, calling `skipBack()` / `skipForward()` on the view model and `pauseInactivityTimer()` during the scrub
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.8, 7.4_

  - [x] 3.4 Create `PlaybackControlsView`
    - Add `RingAppleTV/Sources/Views/Player/Controls/PlaybackControlsView.swift`
    - Horizontal `HStack` with skip-back, play/pause, skip-forward buttons
    - Play/pause icon reflects `viewModel.playerViewModel.isPlaying`
    - Skip-forward rendered with `.opacity(0.5)` and `.disabled(true)` when `viewModel.isAtLiveEdge`
    - All three buttons bind their focus to `ControlFocus` values
    - _Requirements: 4.1, 4.2, 4.4, 4.5, 4.6, 6.1, 7.3_

  - [x] 3.5 Create `LiveButton`
    - Add `RingAppleTV/Sources/Views/Player/Controls/LiveButton.swift`
    - Focusable button with "Live" label and dot indicator
    - Visible only when `!viewModel.isAtLiveEdge`
    - On select, calls `viewModel.jumpToLive()`
    - _Requirements: 3.6, 3.7_

  - [x] 3.6 Create `MuteToggleView`
    - Add `RingAppleTV/Sources/Views/Player/Controls/MuteToggleView.swift`
    - Button with SF Symbol `speaker.wave.2.fill` when unmuted, `speaker.slash.fill` when muted
    - On select, calls `viewModel.toggleMute()`
    - Positioned at the bottom-right of the overlay
    - _Requirements: 5.1, 5.2, 5.3, 7.5_

- [x] 4. Overlay container
  - [x] 4.1 Create `PlayerControlsOverlay`
    - Add `RingAppleTV/Sources/Views/Player/Controls/PlayerControlsOverlay.swift`
    - `ZStack` with a top+bottom semi-transparent gradient background
    - `@FocusState private var focusedControl: ControlFocus?`
    - Composition: `CameraSwitcherView` (top-center), `PlaybackControlsView` (center) with `LiveButton` beside it when not live, `TimelineBarView` (bottom, full-width padded), `MuteToggleView` (bottom-right)
    - Sheet presentation of `CameraPickerView` bound to `viewModel.isCameraPickerPresented`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_

  - [x] 4.2 Apply fade show/hide animation
    - Conditionally render the overlay only when `viewModel.isOverlayVisible`
    - Use `.transition(.opacity)` with `.animation(.easeInOut(duration: PlayerControlsConstants.fadeAnimationDuration), value: viewModel.isOverlayVisible)`
    - When hidden, overlay contains no focusable elements (removed from the view hierarchy)
    - _Requirements: 1.1, 1.2, 1.5, 1.6, 6.6, 7.6_

  - [x] 4.3 Wire focus routing
    - On appear, set `focusedControl = .playPause`
    - Focus sections: top row (`cameraSwitcher`), middle row (`skipBack`, `playPause`, `skipForward`, `liveButton`), bottom-right (`muteToggle`)
    - `.focusSection()` on each horizontal group so up/down swipes move between rows and left/right move within a row
    - Use `.prefersDefaultFocus(in:)` and a `Namespace` to bias initial focus onto play/pause
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [x] 4.4 Reset timer on any control interaction
    - Each subview's action closure calls `viewModel.resetInactivityTimer()` before (or as part of) delegating to the view model action
    - Ensure camera picker selection, scrubbing, play/pause, skip, and mute all reset the timer
    - _Requirements: 1.4_

- [x] 5. PlayerView integration
  - [x] 5.1 Instantiate `PlayerControlsViewModel` in `PlayerView`
    - Update `PlayerView.swift` (`RingAppleTV/Sources/Views/Player/PlayerView.swift`) to accept a `PlayerControlsViewModel` built by the caller
    - Update `ServiceContainer.makePlayerViewModel()` (or a new `makePlayerControlsViewModel(for:)` factory) to construct the controls view model with `deviceService` and `eventService`
    - Update `MainTabView.playerViewBuilder` to pass the controls view model into `PlayerView`
    - _Requirements: 2.2, 3.1_

  - [x] 5.2 Layer `PlayerControlsOverlay` over `playerContent`
    - In `PlayerView.body`, wrap the `ZStack` so `PlayerControlsOverlay` renders above the video content
    - Preserve existing `sourceBanner` and `deviceNameOverlay`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_

  - [x] 5.3 Center-click toggles overlay visibility
    - Add `.onTapGesture { controlsViewModel.toggleOverlay() }` to the player content `ZStack` (active only when `state == .loaded`)
    - Ensure the gesture doesn't conflict with overlay button selections: when the overlay is visible, the controls take input; when hidden, the tap surfaces to the root
    - _Requirements: 1.1, 1.2_

  - [x] 5.4 Hardware Play/Pause button handling
    - On tvOS, install a `.onPlayPauseCommand { controlsViewModel.togglePlayPause() }` modifier on `PlayerView` so the hardware button works regardless of overlay visibility
    - _Requirements: 4.3_

  - [x] 5.5 Preserve Menu-button dismiss
    - Keep the existing outer `.focusable(true).onExitCommand { dismiss() }`
    - Verify the overlay's focus sections do not swallow the Menu press
    - _Requirements: 6.5_

  - [x] 5.6 Initial data load on appear
    - When `PlayerView` transitions to `.loaded`, call `controlsViewModel.loadAvailableDevices()` and `controlsViewModel.loadEvents()` (concurrently via `async let`)
    - Errors are logged and swallowed; the overlay falls back to no camera switcher and no timeline markers as specified in the design's error handling table
    - _Requirements: 2.7, 3.1_

- [x] 6. Checkpoint — Build and manual smoke test
  - Build the project (Xcode or `xcodebuild`) and run on the tvOS simulator
  - Verify: center click toggles overlay; play/pause button works; camera switcher appears when ≥2 devices; timeline shows event dots; mute toggles; Menu dismisses
  - Ensure no regression in existing `PlayerView` states (loading, error, disconnected)

- [x] 7. Unit tests
  - [x] 7.1 Tests for `PlayerControlsViewModel` overlay state
    - Add `RingAppleTV/Tests/ViewModels/PlayerControlsViewModelTests.swift`
    - `toggleOverlay()` flips visibility
    - `showOverlay()` starts the inactivity timer; `hideOverlay()` invalidates it
    - Timer expiry sets `isOverlayVisible = false` (use a mocked clock or short override for testability)
    - `resetInactivityTimer()` restarts the countdown
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

  - [x] 7.2 Tests for camera switching
    - `loadAvailableDevices()` populates `availableDevices` from `MockDeviceService`
    - `selectCamera(_:)` stops then starts the stream and updates `activeDevice`
    - Dismissing the picker without selecting leaves state unchanged
    - Camera switcher is hidden with one device
    - _Requirements: 2.2, 2.3, 2.4, 2.5, 2.6, 2.7_

  - [x] 7.3 Tests for timeline navigation
    - `skipBack()` / `skipForward()` move through events and clamp at the earliest event and live edge
    - `jumpToLive()` resumes a live stream and sets `isAtLiveEdge = true`
    - Scrubbing pauses the inactivity timer
    - _Requirements: 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 4.4, 4.5, 4.6_

  - [x] 7.4 Tests for mute persistence
    - `toggleMute()` inverts `isMuted`
    - Mute state is preserved across a `selectCamera(_:)` call
    - _Requirements: 5.2, 5.3, 5.4_

  - [x] 7.5 Tests for playback controls
    - `togglePlayPause()` inverts `playerViewModel.isPlaying`
    - Skip-forward is disabled at the live edge (assertion on computed `isSkipForwardEnabled` property or equivalent)
    - _Requirements: 4.2, 4.3, 4.6_

- [x] 8. Property-based tests
  - Library: `swift-testing` with randomized parameterized inputs (min 100 iterations per property)
  - Tag format: `Feature: player-controls, Property N: <property text>`
  - Add `RingAppleTV/Tests/PropertyTests/PlayerControlsPropertyTests.swift`

  - [x] 8.1 Property 1: Overlay toggle is an involution
    - For any initial visibility state, `toggleOverlay()` invoked twice returns to the original state
    - _Validates: Requirements 1.1, 1.2_

  - [x] 8.2 Property 2: Any interaction resets inactivity timer
    - For any sampled interaction (play/pause, skip, mute, camera switcher, scrub), the timer's remaining time after the interaction equals `inactivityTimeout`
    - _Validates: Requirement 1.4_

  - [x] 8.3 Property 3: Camera switch transitions stream correctly
    - For any `A ≠ B` in a generated device list, `selectCamera(B)` results in one `stopStream` call followed by one `requestStream(B)` call and `activeDevice == B`
    - Uses `MockStreamSessionManager` and a counting `MockPlayerViewModel`
    - _Validates: Requirements 2.3, 2.4, 2.5_

  - [x] 8.4 Property 4: Camera switcher hidden for single device
    - For any single-device list, `CameraSwitcherView.isHidden == true`
    - _Validates: Requirement 2.7_

  - [x] 8.5 Property 5: Timeline navigation respects bounds
    - For any events list (0–50 entries) and any starting position, backward from index 0 stays at 0, forward from live stays at live, backward from live goes to last event, and forward from last event goes to live
    - _Validates: Requirements 3.3, 3.4, 3.6, 4.4, 4.5, 4.6_

  - [x] 8.6 Property 6: Scrubbing pauses inactivity timer
    - For any scrub interaction, the timer is paused for the scrub duration and does not fire during scrubbing
    - _Validates: Requirement 3.8_

  - [x] 8.7 Property 7: Play/pause toggle works regardless of overlay visibility
    - For any combination of `isOverlayVisible` and `isPlaying`, `togglePlayPause()` inverts `isPlaying`
    - _Validates: Requirements 4.2, 4.3_

  - [x] 8.8 Property 8: Mute toggle inverts audio state
    - For any `isMuted` state, `toggleMute()` produces the opposite state
    - _Validates: Requirements 5.2, 5.3_

  - [x] 8.9 Property 9: Mute state persists across camera switches
    - For any mute state and any sequence of `selectCamera(_:)` calls within a session, the mute state after each switch equals the state before
    - _Validates: Requirement 5.4_

- [x] 9. Mocks and test support
  - [x] 9.1 Extend `MockDeviceService` with a configurable device list
    - Add a property-backed result for `fetchDevices()` so property tests can drive varied device counts
    - File: `RingAppleTV/Tests/Mocks/MockDeviceService.swift`

  - [x] 9.2 Extend `MockEventService` with a configurable events list
    - Add a property-backed result for `fetchEvents(for:)`
    - File: `RingAppleTV/Tests/Mocks/MockEventService.swift`

  - [x] 9.3 Add generators to `TestDataGenerators`
    - `randomDevice(online:)`, `randomEvents(count:)`, `randomTimelinePosition(events:)`, `randomInteractionType()`
    - File: `RingAppleTV/Tests/Helpers/TestDataGenerators.swift`

- [x] 10. Accessibility pass
  - [x] 10.1 Add `accessibilityLabel` + `accessibilityHint` to every control
    - Camera switcher, skip-back, play/pause, skip-forward, live button, mute toggle, timeline event markers
    - Disabled state on skip-forward announces "Unavailable at live edge"
  - [x] 10.2 Verify VoiceOver focus order matches the visual layout (top to bottom, left to right within each row)
  - _Requirements: Supports 4.6 (disabled announcement) and general accessibility_

- [x] 11. Final checkpoint — Ensure all tests pass
  - Run the full test suite (unit + property) and the project build
  - Fix any regressions before concluding the feature

## Notes

- All new views live under `RingAppleTV/Sources/Views/Player/Controls/` to keep them grouped with `PlayerView`.
- `PlayerControlsViewModel` reuses existing services via `ServiceContainer`; no new service protocols are introduced.
- The overlay renders only when visible to keep tvOS focus management simple — this also satisfies Requirement 1.6 (no focusable elements while hidden).
- Mute state is session-scoped and intentionally not persisted across app launches, per design.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "1.3"] },
    { "id": 1, "tasks": ["2.1"] },
    { "id": 2, "tasks": ["2.2", "2.3", "2.4", "2.5"] },
    { "id": 3, "tasks": ["3.1", "3.2", "3.3", "3.4", "3.5", "3.6"] },
    { "id": 4, "tasks": ["4.1"] },
    { "id": 5, "tasks": ["4.2", "4.3", "4.4"] },
    { "id": 6, "tasks": ["5.1"] },
    { "id": 7, "tasks": ["5.2", "5.3", "5.4", "5.5", "5.6"] },
    { "id": 8, "tasks": ["6"] },
    { "id": 9, "tasks": ["9.1", "9.2", "9.3"] },
    { "id": 10, "tasks": ["7.1", "7.2", "7.3", "7.4", "7.5"] },
    { "id": 11, "tasks": ["8.1", "8.2", "8.3", "8.4", "8.5", "8.6", "8.7", "8.8", "8.9"] },
    { "id": 12, "tasks": ["10.1", "10.2"] },
    { "id": 13, "tasks": ["11"] }
  ]
}
```
