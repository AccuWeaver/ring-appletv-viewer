import XCTest
@testable import RingAppleTV

/// Overlay-state tests for `PlayerControlsViewModel` (spec task 7.1).
///
/// Covers Requirements 1.1–1.5: `toggleOverlay()` flips visibility,
/// `showOverlay()` arms the inactivity auto-hide timer, `hideOverlay()`
/// invalidates it, timer expiry hides the overlay, and
/// `resetInactivityTimer()` restarts the countdown.
///
/// The 5-second `PlayerControlsConstants.inactivityTimeout` is a hard-coded
/// constant, so the timer-expiry and reset tests run in real time via
/// `XCTestExpectation` with timeouts slightly longer than the constant.
/// These tests are intentionally kept minimal to balance runtime against
/// coverage of the timer wiring.
@MainActor
final class PlayerControlsViewModelTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a SUT backed by real `PlayerControlsViewModel` / `PlayerViewModel`
    /// instances plus protocol-conforming test doubles. The stream manager is
    /// returned so timer-independent tests can assert on it if needed; overlay
    /// tests here mostly care about `isOverlayVisible`.
    ///
    /// Callers that need to drive `loadAvailableDevices` or `selectCamera`
    /// flows can pass custom `deviceService` / `eventService` doubles so the
    /// returned tuple exposes those for assertions.
    private func makeSUT(
        activeDevice: RingDevice = MockData.doorbell,
        deviceService: MockDeviceService = MockDeviceService(),
        eventService: MockEventService = MockEventService()
    ) -> (
        sut: PlayerControlsViewModel,
        streamManager: MockStreamSessionManager,
        deviceService: MockDeviceService,
        eventService: MockEventService
    ) {
        let streamManager = MockStreamSessionManager()
        let playerViewModel = PlayerViewModel(streamSessionManager: streamManager)
        let sut = PlayerControlsViewModel(
            playerViewModel: playerViewModel,
            deviceService: deviceService,
            eventService: eventService,
            activeDevice: activeDevice
        )
        return (sut, streamManager, deviceService, eventService)
    }

    /// Pumps the main run loop for `seconds` real time so scheduled `Timer`
    /// callbacks have a chance to fire. Uses `DispatchQueue.main.asyncAfter`
    /// instead of `Thread.sleep` because sleeping the main thread would
    /// block the very run loop the timer needs to fire on.
    private func waitMain(seconds: TimeInterval) {
        let exp = expectation(description: "wait \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: seconds + 2.0)
    }

    // MARK: - Requirements 1.1, 1.2: toggleOverlay flips visibility

    func test_toggleOverlay_flipsVisibilityHiddenToVisibleAndBack() {
        let (sut, _, _, _) = makeSUT()
        XCTAssertFalse(sut.isOverlayVisible, "Precondition: overlay starts hidden")

        sut.toggleOverlay()
        XCTAssertTrue(sut.isOverlayVisible, "toggleOverlay() from hidden should make visible")

        sut.toggleOverlay()
        XCTAssertFalse(sut.isOverlayVisible, "toggleOverlay() from visible should make hidden")
    }

    // MARK: - Requirement 1.1: showOverlay sets visibility true

    func test_showOverlay_setsIsOverlayVisibleTrue() {
        let (sut, _, _, _) = makeSUT()
        sut.showOverlay()
        XCTAssertTrue(sut.isOverlayVisible)
        sut.hideOverlay() // tidy up the scheduled timer
    }

    // MARK: - Requirement 1.2: hideOverlay clears visibility

    func test_hideOverlay_setsIsOverlayVisibleFalse() {
        let (sut, _, _, _) = makeSUT()
        sut.showOverlay()
        sut.hideOverlay()
        XCTAssertFalse(sut.isOverlayVisible)
    }

    // MARK: - Requirements 1.3, 1.5: timer expiry hides overlay

    /// `showOverlay()` schedules a `Timer` for `inactivityTimeout` seconds.
    /// When that timer fires with no intervening reset, the overlay hides
    /// automatically. This test runs in real time so the actual run-loop
    /// timer fires.
    func test_timerExpiry_autoHidesOverlayAfterInactivityTimeout() {
        let (sut, _, _, _) = makeSUT()
        sut.showOverlay()
        XCTAssertTrue(sut.isOverlayVisible, "Precondition: visible immediately after show")

        waitMain(seconds: PlayerControlsConstants.inactivityTimeout + 0.75)

        XCTAssertFalse(
            sut.isOverlayVisible,
            "Overlay should auto-hide after \(PlayerControlsConstants.inactivityTimeout)s of inactivity"
        )
    }

    // MARK: - Requirement 1.4: resetInactivityTimer restarts the countdown

    /// Shows the overlay, waits partway through the original countdown, calls
    /// `resetInactivityTimer()`, then waits again so the total elapsed time
    /// since show exceeds `inactivityTimeout`. Without a reset, the overlay
    /// would have auto-hidden; with a reset, the fresh countdown keeps it
    /// visible.
    ///
    /// Also covers the invalidation path on `hideOverlay()` implicitly: if
    /// the old timer hadn't been cancelled-and-replaced by the reset call,
    /// the original timer would fire during the second wait and hide the
    /// overlay.
    func test_resetInactivityTimer_extendsCountdownSoOverlayStaysVisible() {
        let (sut, _, _, _) = makeSUT()

        // Use a partial window so `preResetWait + postResetWait > timeout`
        // but `postResetWait < timeout`. That proves reset extended past the
        // original deadline without waiting a full new timeout.
        let timeout = PlayerControlsConstants.inactivityTimeout
        let preResetWait = timeout - 2.0     // e.g. 3.0s
        let postResetWait = timeout - 2.0    // e.g. 3.0s (total 6s > 5s)

        sut.showOverlay()

        waitMain(seconds: preResetWait)
        XCTAssertTrue(sut.isOverlayVisible, "Precondition: visible before the original timer would fire")

        sut.resetInactivityTimer()

        waitMain(seconds: postResetWait)
        XCTAssertTrue(
            sut.isOverlayVisible,
            "Overlay should still be visible after reset extended the countdown past the original deadline"
        )

        sut.hideOverlay() // cancel the pending timer before tearDown
    }

    // MARK: - Task 7.2: Camera Switching
    // Covers Requirements 2.2, 2.3, 2.4, 2.5, 2.6, 2.7.

    /// Helper to build an online `RingDevice` with a unique id/name so we can
    /// assert activeDevice / availableDevices contents without reaching into
    /// `MockData` for more fixtures than it exposes.
    private func onlineDevice(id: String, name: String) -> RingDevice {
        RingDevice(
            id: id,
            name: name,
            model: "stickup_cam",
            deviceType: .stickupCam,
            firmwareVersion: "1.0.0",
            powerSource: .battery,
            isOnline: true
        )
    }

    private func offlineDevice(id: String, name: String) -> RingDevice {
        RingDevice(
            id: id,
            name: name,
            model: "stickup_cam",
            deviceType: .stickupCam,
            firmwareVersion: "1.0.0",
            powerSource: .battery,
            isOnline: false
        )
    }

    // MARK: - Requirement 2.2: loadAvailableDevices populates the list

    /// `loadAvailableDevices()` delegates to `DeviceService.fetchDevices()`
    /// and assigns the result to `availableDevices` so the picker has
    /// something to render.
    func test_loadAvailableDevices_populatesAvailableDevices() async {
        let deviceService = MockDeviceService()
        let devices = [
            onlineDevice(id: "a", name: "Front Door"),
            onlineDevice(id: "b", name: "Back Yard"),
            onlineDevice(id: "c", name: "Driveway")
        ]
        deviceService.fetchDevicesResult = .success(devices)

        let (sut, _, _, _) = makeSUT(deviceService: deviceService)
        await sut.loadAvailableDevices()

        XCTAssertEqual(sut.availableDevices.count, 3)
        XCTAssertEqual(sut.availableDevices.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Requirement 2.2: offline devices are excluded

    /// The camera picker should only surface cameras the user can actually
    /// switch to — offline ones are filtered out by
    /// `loadAvailableDevices()`.
    func test_loadAvailableDevices_filtersOfflineDevices() async {
        let deviceService = MockDeviceService()
        let devices = [
            onlineDevice(id: "a", name: "Front Door"),
            offlineDevice(id: "b", name: "Side Gate"),
            onlineDevice(id: "c", name: "Driveway"),
            offlineDevice(id: "d", name: "Garage")
        ]
        deviceService.fetchDevicesResult = .success(devices)

        let (sut, _, _, _) = makeSUT(deviceService: deviceService)
        await sut.loadAvailableDevices()

        XCTAssertEqual(sut.availableDevices.count, 2)
        XCTAssertEqual(Set(sut.availableDevices.map(\.id)), ["a", "c"])
        XCTAssertTrue(
            sut.availableDevices.allSatisfy { $0.isOnline },
            "availableDevices should contain only online devices"
        )
    }

    // MARK: - Requirements 2.3, 2.4, 2.5: selectCamera transitions the stream

    /// Switching cameras must tear down the current stream, start a new one
    /// on the selected device, and point `activeDevice` at the chosen
    /// camera. `stopStream()` on `PlayerViewModel` is fire-and-forget so we
    /// give the detached task a beat to land before inspecting the mock.
    func test_selectCamera_updatesActiveDeviceAndCallsStream() async {
        let initial = MockData.doorbell
        let other = onlineDevice(id: "b", name: "Back Yard")

        let (sut, streamManager, _, _) = makeSUT(activeDevice: initial)

        await sut.selectCamera(other)

        // Let the fire-and-forget stopStream Task inside PlayerViewModel land.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(sut.activeDevice.id, other.id, "activeDevice should update to the selected device")
        XCTAssertGreaterThanOrEqual(
            streamManager.stopStreamCalls, 1,
            "selectCamera() should stop the current stream before starting the new one"
        )
        XCTAssertEqual(
            streamManager.startStreamCalls.last?.deviceId, other.id,
            "Last startStream call should target the newly selected device"
        )
        XCTAssertEqual(
            streamManager.startStreamCalls.last?.powerSource, other.powerSource,
            "startStream should carry the selected device's power source"
        )
    }

    // MARK: - Requirement 2.6: dismissing the picker without selecting is a no-op

    /// Picker dismiss is a view concern, but at the view-model level it
    /// amounts to toggling `isCameraPickerPresented` without ever calling
    /// `selectCamera`. In that flow, `activeDevice` and the stream must
    /// remain unchanged.
    func test_cameraPickerDismissedWithoutSelection_leavesStateUnchanged() async {
        let initial = MockData.doorbell
        let (sut, streamManager, _, _) = makeSUT(activeDevice: initial)

        sut.isCameraPickerPresented = true
        // Simulate the user backing out with no selection.
        sut.isCameraPickerPresented = false

        // Let any spurious tasks settle before asserting.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sut.activeDevice.id, initial.id, "activeDevice should not change when picker is dismissed")
        XCTAssertEqual(
            streamManager.stopStreamCalls, 0,
            "No stream teardown should happen when the picker is dismissed without a selection"
        )
        XCTAssertTrue(
            streamManager.startStreamCalls.isEmpty,
            "No new stream should start when the picker is dismissed without a selection"
        )
    }

    // MARK: - Requirement 2.7: camera switcher is hidden with one device

    /// The `CameraSwitcherView` hides itself when `availableDevices.count <= 1`;
    /// the view-model contract this rests on is that `loadAvailableDevices()`
    /// produces the correct count. Asserting on the count here is the VM-level
    /// proxy for the view-level requirement.
    func test_loadAvailableDevices_withSingleDevice_exposesCountOfOne() async {
        let deviceService = MockDeviceService()
        deviceService.fetchDevicesResult = .success([
            onlineDevice(id: "a", name: "Front Door")
        ])

        let (sut, _, _, _) = makeSUT(deviceService: deviceService)
        await sut.loadAvailableDevices()

        XCTAssertEqual(
            sut.availableDevices.count, 1,
            "availableDevices.count == 1 drives CameraSwitcherView to render as hidden"
        )
    }

    // MARK: - Task 7.3: Timeline Navigation
    // Covers Requirements 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 4.4, 4.5, 4.6.

    /// Builds a minimal `RingEvent` with a caller-supplied id so list-based
    /// assertions can distinguish events without pulling in more fixtures
    /// from `MockData`. Other fields are constants that don't affect the
    /// navigation logic under test.
    private func makeEvent(id: String) -> RingEvent {
        RingEvent(
            id: id,
            deviceId: "10",
            eventType: .motion,
            createdAt: Date().addingTimeInterval(-3600),
            duration: 30
        )
    }

    // MARK: - Requirements 3.3, 4.4: skipBack from live edge moves to the most-recent event

    /// Scrubbing back from the live edge drops the playhead onto the last
    /// event in the timeline and clears `isAtLiveEdge`, so the view can
    /// switch from live to recorded playback for that event.
    func test_skipBack_fromLiveEdge_movesToMostRecentEvent() {
        let (sut, _, _, _) = makeSUT()
        sut.events = [makeEvent(id: "e1"), makeEvent(id: "e2"), makeEvent(id: "e3")]
        sut.isAtLiveEdge = true
        sut.currentEventIndex = nil

        sut.skipBack()

        XCTAssertEqual(
            sut.currentEventIndex, 2,
            "skipBack from live edge should move to the most-recent event (index events.count - 1)"
        )
        XCTAssertFalse(
            sut.isAtLiveEdge,
            "skipBack should leave live edge when landing on an event"
        )
    }

    // MARK: - Requirements 3.3, 4.4: skipBack clamps at the earliest event

    /// At the earliest event there's nothing further back to visit; the
    /// playhead must stay put rather than underflow.
    func test_skipBack_atEarliestEvent_clampsAtEarliest() {
        let (sut, _, _, _) = makeSUT()
        sut.events = [makeEvent(id: "e1"), makeEvent(id: "e2"), makeEvent(id: "e3")]
        sut.currentEventIndex = 0
        sut.isAtLiveEdge = false

        sut.skipBack()

        XCTAssertEqual(
            sut.currentEventIndex, 0,
            "skipBack at the earliest event should clamp at index 0"
        )
        XCTAssertFalse(
            sut.isAtLiveEdge,
            "Clamping at the earliest event should not flip back to live edge"
        )
    }

    // MARK: - Requirement 4.6: skipForward at live edge is a no-op

    /// Skip-forward is disabled at the live edge (there's nothing "after"
    /// live). Invoking it from that state should leave the position
    /// unchanged.
    func test_skipForward_atLiveEdge_isNoOp() {
        let (sut, _, _, _) = makeSUT()
        sut.events = [makeEvent(id: "e1"), makeEvent(id: "e2"), makeEvent(id: "e3")]
        sut.isAtLiveEdge = true
        sut.currentEventIndex = nil

        sut.skipForward()

        XCTAssertTrue(
            sut.isAtLiveEdge,
            "skipForward at the live edge should leave isAtLiveEdge == true"
        )
        XCTAssertNil(
            sut.currentEventIndex,
            "skipForward at the live edge should leave currentEventIndex == nil"
        )
    }

    // MARK: - Requirements 3.4, 4.5, 4.6: skipForward from last event transitions to live

    /// Stepping forward off the most-recent event lands at the live edge:
    /// `isAtLiveEdge` flips to `true` and `currentEventIndex` is cleared
    /// so downstream consumers know to re-anchor to live playback.
    func test_skipForward_fromLastEvent_movesToLiveEdge() {
        let (sut, _, _, _) = makeSUT()
        let events = [makeEvent(id: "e1"), makeEvent(id: "e2"), makeEvent(id: "e3")]
        sut.events = events
        sut.currentEventIndex = events.count - 1
        sut.isAtLiveEdge = false

        sut.skipForward()

        XCTAssertTrue(
            sut.isAtLiveEdge,
            "skipForward from the last event should transition to the live edge"
        )
        XCTAssertNil(
            sut.currentEventIndex,
            "skipForward to the live edge should clear currentEventIndex"
        )
    }

    // MARK: - Requirements 3.6, 3.7: jumpToLive restores live playback

    /// Tapping the Live button from an event position must both flip the
    /// published state back to live and kick off a fresh live stream for
    /// the active device. `jumpToLive` wraps the async `requestStream`
    /// call in a `Task`, so the startStream assertion is made after a
    /// brief yield to let that task land on the mock.
    func test_jumpToLive_setsIsAtLiveEdgeTrueAndClearsIndex() async {
        let (sut, streamManager, _, _) = makeSUT()
        sut.events = [makeEvent(id: "e1"), makeEvent(id: "e2"), makeEvent(id: "e3")]
        // Move the playhead off the live edge before jumping back.
        sut.currentEventIndex = 0
        sut.isAtLiveEdge = false

        sut.jumpToLive()

        XCTAssertTrue(
            sut.isAtLiveEdge,
            "jumpToLive should set isAtLiveEdge to true"
        )
        XCTAssertNil(
            sut.currentEventIndex,
            "jumpToLive should clear currentEventIndex"
        )

        // Let the detached Task inside jumpToLive dispatch its async
        // requestStream call through to the mock.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            streamManager.startStreamCalls.last?.deviceId, sut.activeDevice.id,
            "jumpToLive should start a new stream for the active device"
        )
    }

    // MARK: - Requirement 3.8: pauseInactivityTimer prevents auto-hide (scrubbing)

    /// While the user is scrubbing the timeline the overlay must not
    /// auto-hide out from under them. `pauseInactivityTimer()` is the
    /// view-model-level primitive the timeline view calls when a scrub
    /// gesture starts; `resumeInactivityTimer()` is what it calls when
    /// the gesture ends. This test exercises both halves in real time so
    /// the actual `Timer` wiring is verified end-to-end.
    func test_pauseInactivityTimer_whenOverlayVisible_invalidatesTimer() {
        let (sut, _, _, _) = makeSUT()
        let timeout = PlayerControlsConstants.inactivityTimeout

        sut.showOverlay()
        XCTAssertTrue(sut.isOverlayVisible, "Precondition: overlay visible after show")

        // Simulate the start of a scrub gesture.
        sut.pauseInactivityTimer()

        // With the timer paused, waiting past the original deadline must
        // not auto-hide the overlay.
        waitMain(seconds: timeout + 0.75)
        XCTAssertTrue(
            sut.isOverlayVisible,
            "Overlay should remain visible while the inactivity timer is paused (scrubbing)"
        )

        // Simulate the end of the scrub gesture; the timer resumes with
        // a fresh countdown and the overlay hides when it expires.
        sut.resumeInactivityTimer()
        waitMain(seconds: timeout + 0.75)
        XCTAssertFalse(
            sut.isOverlayVisible,
            "Overlay should auto-hide after resume + inactivity timeout"
        )
    }

    // MARK: - Task 7.4: Mute Persistence
    // Covers Requirements 5.2, 5.3, 5.4.

    // MARK: - Requirements 5.2, 5.3: toggleMute inverts isMuted

    /// `toggleMute()` is the overlay-level primitive that flips the
    /// session-scoped audio state. Requirements 5.2 and 5.3 together
    /// describe an involution: calling it twice must return to the
    /// original state.
    func test_toggleMute_invertsIsMuted() {
        let (sut, _, _, _) = makeSUT()
        XCTAssertFalse(sut.isMuted, "Precondition: audio starts unmuted")

        sut.toggleMute()
        XCTAssertTrue(sut.isMuted, "toggleMute() from unmuted should mute")

        sut.toggleMute()
        XCTAssertFalse(sut.isMuted, "toggleMute() from muted should unmute")
    }

    // MARK: - Requirements 5.2, 5.3: toggleMute drives the active transport

    /// The view-model level mute flip must propagate down to
    /// `StreamSessionManager.setAudioMuted(_:)` so the live WebRTC audio
    /// track is actually silenced. Asserting on the mock's recorded calls
    /// verifies the `toggleMute → PlayerViewModel.setMuted → streamManager`
    /// wiring is in place.
    func test_toggleMute_callsSetAudioMutedOnStreamManager() {
        let (sut, streamManager, _, _) = makeSUT()
        XCTAssertTrue(
            streamManager.setAudioMutedCalls.isEmpty,
            "Precondition: no mute calls have been made yet"
        )

        sut.toggleMute()

        XCTAssertEqual(
            streamManager.setAudioMutedCalls.last, true,
            "toggleMute() should forward the new mute state to the stream manager"
        )
    }

    // MARK: - Requirement 5.4: mute state persists across selectCamera

    /// Per Requirement 5.4 the mute toggle is session-scoped, not
    /// device-scoped: switching cameras must not silently un-mute the
    /// viewer. This test toggles mute on, switches to a different device,
    /// and asserts both that `isMuted` is still `true` afterwards and
    /// that `setAudioMuted(true)` was observed on the stream manager as
    /// part of the scenario (the overlay calls it during `toggleMute`,
    /// and `selectCamera` re-applies the state on the fresh session so
    /// the new audio track respects the user's choice).
    func test_isMutedPersistsAcrossSelectCamera() async {
        let initial = MockData.doorbell
        let other = onlineDevice(id: "b", name: "Back Yard")
        let (sut, streamManager, _, _) = makeSUT(activeDevice: initial)

        // Mute via the public toggle so the full wiring (including the
        // stream-manager hop) runs.
        sut.toggleMute()
        XCTAssertTrue(sut.isMuted, "Precondition: audio muted before switch")

        await sut.selectCamera(other)

        // Let the fire-and-forget stopStream Task inside PlayerViewModel
        // land so any trailing calls settle before asserting.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(
            sut.isMuted,
            "isMuted should persist across a selectCamera(_:) call"
        )
        XCTAssertEqual(
            sut.activeDevice.id, other.id,
            "Precondition: selectCamera should have switched the active device"
        )
        XCTAssertTrue(
            streamManager.setAudioMutedCalls.contains(true),
            "setAudioMuted(true) should have been observed as part of the switch flow"
        )
    }

    // MARK: - Task 7.5: Playback Controls
    // Covers Requirements 4.2, 4.3, 4.6.

    // MARK: - Requirements 4.2, 4.3: togglePlayPause inverts isPlaying

    /// The overlay's `togglePlayPause()` delegates into
    /// ``PlayerViewModel/togglePlayPause()``, which per its contract only
    /// flips `isPlaying` when the underlying state is `.loaded`. This test
    /// drives the player into `.loaded` via a successful `requestStream`
    /// (same pattern as `PlayerViewModelTests.testTogglePlayPause_whenLoaded`)
    /// and then asserts two toggles return `isPlaying` to its starting value,
    /// which is an involution over the boolean — the full expression of
    /// Requirements 4.2 and 4.3.
    func test_togglePlayPause_invertsIsPlaying() async {
        let (sut, streamManager, _, _) = makeSUT()
        streamManager.autoTransitionStates = [.connecting, .connected]

        // Drive the underlying PlayerViewModel into `.loaded` so
        // `togglePlayPause()` actually toggles. `requestStream` lands
        // with `isPlaying == true` on success.
        await sut.playerViewModel.requestStream(
            for: sut.activeDevice.id,
            powerSource: sut.activeDevice.powerSource
        )
        XCTAssertTrue(
            sut.playerViewModel.isPlaying,
            "Precondition: PlayerViewModel is playing after a successful requestStream"
        )

        sut.togglePlayPause()
        XCTAssertFalse(
            sut.playerViewModel.isPlaying,
            "togglePlayPause() from playing should pause"
        )

        sut.togglePlayPause()
        XCTAssertTrue(
            sut.playerViewModel.isPlaying,
            "togglePlayPause() from paused should resume playing"
        )
    }

    // MARK: - Requirement 4.6: isAtLiveEdge defaults to true

    /// The view layer's skip-forward disabled state is a direct binding on
    /// `viewModel.isAtLiveEdge` (see `PlaybackControlsView` — `.disabled(...)`
    /// and `.opacity(0.5)` both key off it). The "no-op while at live edge"
    /// behavior itself is covered in task 7.3 by
    /// `test_skipForward_atLiveEdge_isNoOp`; this test anchors the *default*
    /// that drives that disabled state so a regression flipping the initial
    /// value would be caught here rather than only via view-level testing.
    func test_isAtLiveEdge_defaultsToTrue() {
        let (sut, _, _, _) = makeSUT()

        XCTAssertTrue(
            sut.isAtLiveEdge,
            "isAtLiveEdge should default to true so skip-forward renders disabled until the user scrubs"
        )
        XCTAssertNil(
            sut.currentEventIndex,
            "currentEventIndex should default to nil at the live edge"
        )
    }
}
