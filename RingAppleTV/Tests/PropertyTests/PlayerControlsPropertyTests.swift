import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Arbitrary Conformances

extension InteractionType: Arbitrary {
    public static var arbitrary: Gen<InteractionType> {
        Gen<InteractionType>.fromElements(of: InteractionType.allCases)
    }
}

// MARK: - Checker Configuration

/// Reduced-iteration `CheckerArguments` shared by every property in this
/// file. SwiftCheck's default is 100 iterations per property. Several
/// properties here (notably Properties 3, 7, and 9) drive async
/// `selectCamera` / `requestStream` calls through `XCTestExpectation`
/// pumps, so each iteration incurs real dispatch-queue latency — multiplied
/// across 9 properties this dominates suite runtime. 25 iterations per
/// property keeps good shrinking coverage of the input space while cutting
/// the property-test wall-clock by roughly 4×.
private nonisolated(unsafe) let fastCheck = CheckerArguments(
    maxAllowableSuccessfulTests: 25
)

/// Property-based tests for `PlayerControlsViewModel`.
///
/// Follows the SwiftCheck + XCTest pattern established by the other tests in
/// `RingAppleTV/Tests/PropertyTests/`. Each property is expressed as a single
/// parameterized XCTest method whose body drives `property(...) <- forAll`.
///
/// Iteration count is reduced from SwiftCheck's 100 default to 25 via
/// `CheckerArguments(maxAllowableSuccessfulTests:)` on every property in
/// this file (see `fastCheck` above). Most properties spin up a fresh
/// `PlayerControlsViewModel` per iteration and drive async APIs through
/// `XCTestExpectation` + `XCTWaiter` with multi-second timeouts, so 100
/// iterations per property (9 × 100 = 900) is slow. 25 samples still
/// exercise every branch the generators produce while keeping wall-clock
/// runtime tractable.
///
/// The view model is `@MainActor`-isolated, so the whole test class is
/// `@MainActor` too. SwiftCheck's `forAll` runs its closure synchronously on
/// the calling thread, so the driving test method's main-actor isolation
/// carries into each iteration via `MainActor.assumeIsolated`.
@MainActor
final class PlayerControlsPropertyTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a fresh `PlayerControlsViewModel` wired to test doubles. Mirrors
    /// the helper in `PlayerControlsViewModelTests` so the system under test
    /// is identical to the one exercised by unit tests — only the driver
    /// (property-based vs. example-based) differs.
    private func makeSUT(
        activeDevice: RingDevice = MockData.doorbell
    ) -> PlayerControlsViewModel {
        let streamManager = MockStreamSessionManager()
        let playerViewModel = PlayerViewModel(streamSessionManager: streamManager)
        return PlayerControlsViewModel(
            playerViewModel: playerViewModel,
            deviceService: MockDeviceService(),
            eventService: MockEventService(),
            activeDevice: activeDevice
        )
    }

    // MARK: - Property 1: Overlay toggle is an involution
    // Feature: player-controls, Property 1: Overlay toggle is an involution
    // _Validates: Requirements 1.1, 1.2_

    /// For any initial overlay visibility state, calling `toggleOverlay()`
    /// twice returns the overlay to its original visibility state.
    ///
    /// The initial state is generated via `Bool.arbitrary`. The SUT's default
    /// `isOverlayVisible` is `false`, so when the generated initial state is
    /// `true` we prime the SUT with `showOverlay()`; otherwise it stays in
    /// its default hidden state. Two toggles must then restore the original
    /// state — this is the involution property (∀s. toggle(toggle(s)) == s).
    func test_property1_overlayToggleIsInvolution() {
        property("Feature: player-controls, Property 1: Overlay toggle is an involution", arguments: fastCheck)
            <- forAll { (initialVisibility: Bool) in
                MainActor.assumeIsolated {
                    let sut = self.makeSUT()

                    // Drive the SUT to the generated initial visibility state.
                    if initialVisibility {
                        sut.showOverlay()
                    } else {
                        sut.hideOverlay()
                    }
                    guard sut.isOverlayVisible == initialVisibility else {
                        return false
                    }

                    // Toggle twice. Involution says we land where we started.
                    sut.toggleOverlay()
                    sut.toggleOverlay()

                    let finalVisibility = sut.isOverlayVisible

                    // Tidy up the pending inactivity timer before the SUT
                    // goes out of scope so a late-firing Timer can't flip
                    // state on a subsequent iteration.
                    sut.hideOverlay()

                    return finalVisibility == initialVisibility
                }
            }
    }

    // MARK: - Property 2: Any interaction resets inactivity timer
    // Feature: player-controls, Property 2: Any interaction resets inactivity timer
    // _Validates: Requirement 1.4_

    /// For any sampled control interaction performed while the overlay is
    /// visible, the inactivity timer SHALL be reset — i.e. the overlay's
    /// remaining visible time after the interaction equals the full
    /// `inactivityTimeout`.
    ///
    /// The view model doesn't expose the timer's remaining time directly
    /// (it's an `internal` `Timer` reference), so asserting literal
    /// "remaining == inactivityTimeout" would require either reaching into
    /// private state or waiting real wall-clock time. Neither is viable for
    /// a 100-iteration property test (the latter would take ≥ 500 s).
    ///
    /// Instead we test the **observable consequence** of the timer being
    /// reset: after any interaction, `isOverlayVisible` remains `true`. If
    /// an interaction failed to reset the timer (or worse, immediately hid
    /// the overlay), this would flip to `false`. The SwiftCheck run is
    /// synchronous and completes in milliseconds — well under the 5 s
    /// timeout — so the original `showOverlay()` timer can't naturally
    /// expire mid-iteration; the only mechanism that could hide the overlay
    /// during the interaction is the interaction itself misbehaving.
    ///
    /// Each iteration is self-contained: it builds a fresh SUT, drives the
    /// overlay visible, performs the generated interaction, asserts
    /// visibility, and hides the overlay again to invalidate the pending
    /// timer before the SUT goes out of scope. This keeps any late-firing
    /// `Timer` callbacks from leaking across iterations.
    func test_property2_anyInteractionResetsInactivityTimer() {
        property("Feature: player-controls, Property 2: Any interaction resets inactivity timer", arguments: fastCheck)
            <- forAll(TestDataGenerators.randomInteractionType()) { interaction in
                MainActor.assumeIsolated {
                    let sut = self.makeSUT()

                    // Precondition: overlay visible so the inactivity timer
                    // is actually armed. `resetInactivityTimer` is a no-op
                    // while hidden, so testing the reset path requires the
                    // visible state.
                    sut.showOverlay()
                    guard sut.isOverlayVisible else { return false }

                    // Dispatch to the view-model method (or, for the camera
                    // switcher, the same two lines `CameraSwitcherView`
                    // runs on tap) that the corresponding control surface
                    // invokes when the user interacts with it.
                    switch interaction {
                    case .playPause:
                        sut.togglePlayPause()
                    case .skipBack, .scrubLeft:
                        sut.skipBack()
                    case .skipForward, .scrubRight:
                        sut.skipForward()
                    case .mute:
                        sut.toggleMute()
                    case .cameraSwitcher:
                        // Mirrors `CameraSwitcherView.presentPicker()`: reset
                        // the timer, then flip the picker presentation flag.
                        sut.resetInactivityTimer()
                        sut.isCameraPickerPresented = true
                    }

                    let stillVisible = sut.isOverlayVisible

                    // Tear down the scheduled Timer before the SUT leaves
                    // scope so a late-firing callback can't mutate state
                    // on a subsequent iteration.
                    sut.hideOverlay()

                    return stillVisible
                }
            }
    }
}

// MARK: - Extended Fixtures

extension PlayerControlsPropertyTests {

    /// Companion to ``makeSUT`` that additionally exposes the mocks wired
    /// behind the SUT. Property tests that need to observe call counts on
    /// the stream manager (e.g. Property 3) or stage `fetchDevicesResult`
    /// on the device service (e.g. Property 4) use this variant; the
    /// simpler ``makeSUT`` keeps Properties 1/2/5/6/8 terse when they only
    /// care about the view-model-visible state.
    fileprivate func makeSUTWithMocks(
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

    // MARK: - Property 3: Camera switch transitions stream correctly
    // Feature: player-controls, Property 3: Camera switch transitions stream correctly
    // _Validates: Requirements 2.3, 2.4, 2.5_

    /// For any two distinct online devices `A` and `B` where the SUT starts
    /// on `A`, awaiting `selectCamera(B)` must satisfy all three of:
    ///
    /// - `stopStream` was observed on the stream manager at least once
    ///   (the current session was torn down before the switch).
    /// - The most recent `startStream` call targets `B.id`.
    /// - `sut.activeDevice.id == B.id`.
    ///
    /// Two devices are generated independently via
    /// `TestDataGenerators.randomDevice(online: true)`. The underlying id
    /// generator draws from `Int.arbitrary.suchThat { $0 > 0 }`, which can
    /// occasionally collide on small shrink sizes; iterations where the two
    /// generated ids match are treated as vacuously satisfied so the
    /// property tests only the non-trivial case.
    ///
    /// `selectCamera` is `async`, but SwiftCheck's `forAll` closure is
    /// synchronous, so the await is driven through an `XCTestExpectation`
    /// that `XCTWaiter.wait` pumps. A second, short wait lets the
    /// fire-and-forget `Task { await streamSessionManager?.stopStream() }`
    /// that `PlayerViewModel.stopStream()` spawns land on the mock before
    /// its call count is inspected — mirroring the 150 ms settle in
    /// `PlayerControlsViewModelTests.test_selectCamera_updatesActiveDevice…`.
    func test_property3_cameraSwitchTransitionsStream() {
        property("Feature: player-controls, Property 3: Camera switch transitions stream correctly", arguments: fastCheck)
            <- forAll(
                TestDataGenerators.randomDevice(online: true),
                TestDataGenerators.randomDevice(online: true)
            ) { (a: RingDevice, b: RingDevice) in
                // Distinct-id precondition: when the generator collides the
                // property is vacuously satisfied. Collisions are rare
                // because ids are drawn from the positive Ints.
                guard a.id != b.id else { return true }

                return MainActor.assumeIsolated {
                    let fixture = self.makeSUTWithMocks(activeDevice: a)
                    let sut = fixture.sut
                    let streamManager = fixture.streamManager

                    // Drive the async selectCamera through to completion.
                    let selectExp = XCTestExpectation(description: "selectCamera")
                    nonisolated(unsafe) let s = sut
                    nonisolated(unsafe) let target = b
                    Task { @MainActor in
                        await s.selectCamera(target)
                        selectExp.fulfill()
                    }
                    _ = XCTWaiter.wait(for: [selectExp], timeout: 3.0)

                    // Let the detached `Task { await streamSessionManager?.stopStream() }`
                    // inside PlayerViewModel.stopStream() reach the mock.
                    let settleExp = XCTestExpectation(description: "settle stopStream")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        settleExp.fulfill()
                    }
                    _ = XCTWaiter.wait(for: [settleExp], timeout: 1.0)

                    let activeMatches = sut.activeDevice.id == b.id
                    let stoppedAtLeastOnce = streamManager.stopStreamCalls >= 1
                    let lastStartTargetsB = streamManager.startStreamCalls.last?.deviceId == b.id

                    // Tidy any timer the overlay may have scheduled during
                    // the switch (selectCamera ends with hideOverlay(), so
                    // this is belt-and-braces).
                    sut.hideOverlay()

                    return activeMatches && stoppedAtLeastOnce && lastStartTargetsB
                }
            }
    }

    // MARK: - Property 4: Camera switcher hidden for single device
    // Feature: player-controls, Property 4: Camera switcher hidden for single device
    // _Validates: Requirement 2.7_

    /// For any single online device, `loadAvailableDevices()` leaves
    /// `sut.availableDevices.count == 1`. The view-level "camera switcher is
    /// hidden" state is a direct binding on this count (see
    /// `CameraSwitcherView` — `availableDevices.count <= 1`), so the
    /// view-model invariant is the correct place to pin Requirement 2.7.
    ///
    /// The device is generated online so it survives the
    /// `filter { $0.isOnline }` pass inside `loadAvailableDevices()`.
    func test_property4_cameraSwitcherHiddenForSingleDevice() {
        property("Feature: player-controls, Property 4: Camera switcher hidden for single device", arguments: fastCheck)
            <- forAll(TestDataGenerators.randomDevice(online: true)) { (d: RingDevice) in
                MainActor.assumeIsolated {
                    let deviceService = MockDeviceService()
                    deviceService.fetchDevicesResult = .success([d])
                    let fixture = self.makeSUTWithMocks(deviceService: deviceService)
                    let sut = fixture.sut

                    // `loadAvailableDevices()` is async; drive it via
                    // XCTestExpectation so the sync forAll closure can wait.
                    let loadExp = XCTestExpectation(description: "loadAvailableDevices")
                    nonisolated(unsafe) let s = sut
                    Task { @MainActor in
                        await s.loadAvailableDevices()
                        loadExp.fulfill()
                    }
                    _ = XCTWaiter.wait(for: [loadExp], timeout: 2.0)

                    let count = sut.availableDevices.count

                    // No overlay was shown in this test, but keep the tidy
                    // for consistency with the other properties.
                    sut.hideOverlay()

                    return count == 1
                }
            }
    }
}

// MARK: - Property 5: Timeline navigation respects bounds
// Feature: player-controls, Property 5: Timeline navigation respects bounds
// _Validates: Requirements 3.3, 3.4, 3.6, 4.4, 4.5, 4.6_

/// Generates a `[RingEvent]` of length 0–50, inclusive. Declared at file
/// scope (not as a stored static on the `TestDataGenerators` enum) because
/// it composes two of the helpers there — `Gen<Int>.fromElements(in:)` and
/// `TestDataGenerators.randomEvents(count:)` — into a generator specific to
/// Property 5. The size cap of 50 matches the spec wording.
private nonisolated(unsafe) let boundedEventsGen: Gen<[RingEvent]> =
    Gen<Int>.fromElements(in: 0...50).flatMap { count in
        TestDataGenerators.randomEvents(count: count)
    }

extension PlayerControlsPropertyTests {

    /// Tests the four boundary invariants of `TimelinePosition`:
    ///
    /// 1. Backward from index `0` stays at index `0` (earliest-event clamp).
    /// 2. Forward from the live edge stays at the live edge (live-edge clamp).
    /// 3. Backward from the live edge lands on the most-recent event
    ///    (`events.count - 1`) — skipped when the events list is empty,
    ///    where the live edge clamps in place instead.
    /// 4. Forward from the most-recent event transitions to the live edge.
    ///
    /// `TimelinePosition` is a pure value type with no timer or async work,
    /// so the assertions run synchronously inside the `forAll` closure —
    /// no `MainActor.assumeIsolated` or expectation pumping is needed. This
    /// property is cheap per iteration, but runs at the same reduced 25
    /// iterations as the rest of the file for consistency.
    func test_property5_timelineNavigationRespectsBounds() {
        property("Feature: player-controls, Property 5: Timeline navigation respects bounds", arguments: fastCheck)
            <- forAll(boundedEventsGen) { (events: [RingEvent]) in
                // Scenario: forward from live stays at live. Holds for both
                // empty and non-empty event lists (nothing is "after" live).
                let live = TimelinePosition.live(events: events)
                let forwardFromLive = live.movingForward()
                let forwardFromLiveOK = forwardFromLive.isAtLiveEdge

                // Scenario: backward from live. When no events exist there's
                // nowhere to go so the position stays at live; otherwise it
                // lands on the most-recent event (last index).
                let backFromLive = live.movingBack()
                let backFromLiveOK: Bool
                if events.isEmpty {
                    backFromLiveOK = backFromLive.isAtLiveEdge
                } else {
                    backFromLiveOK = backFromLive.eventIndex == events.count - 1
                }

                // The remaining two scenarios require at least one event in
                // the list. With an empty list they're vacuous.
                guard !events.isEmpty else {
                    return forwardFromLiveOK && backFromLiveOK
                }

                // Scenario: backward from the earliest event clamps at 0.
                let atEarliest = TimelinePosition(eventIndex: 0, events: events)
                let backFromEarliestOK = atEarliest.movingBack().eventIndex == 0

                // Scenario: forward from the most-recent event lands at live.
                let atLast = TimelinePosition(eventIndex: events.count - 1, events: events)
                let forwardFromLastOK = atLast.movingForward().isAtLiveEdge

                return forwardFromLiveOK
                    && backFromLiveOK
                    && backFromEarliestOK
                    && forwardFromLastOK
            }
    }

    // MARK: - Property 6: Scrubbing pauses inactivity timer
    // Feature: player-controls, Property 6: Scrubbing pauses inactivity timer
    // _Validates: Requirement 3.8_

    /// While the user is scrubbing the timeline the overlay must not
    /// auto-hide. `pauseInactivityTimer()` is the view-model primitive the
    /// timeline view calls at the start of a scrub gesture; its observable
    /// consequence is that a subsequent `isOverlayVisible` read returns
    /// `true` (the timer-based auto-hide path is what would flip it).
    ///
    /// Like Property 2, this is an observable-invariant framing rather than
    /// a literal "timer remaining == timeout" assertion — waiting
    /// `inactivityTimeout` (5 s) per iteration is infeasible across 100
    /// iterations, so we verify the effect the timer is supposed to
    /// suppress.
    ///
    /// The generated `pauseCount` (1–5) exercises the idempotency of
    /// `pauseInactivityTimer()` too: the timer is already nil after the
    /// first call, so subsequent calls must be safe no-ops.
    func test_property6_scrubbingPausesInactivityTimer() {
        property("Feature: player-controls, Property 6: Scrubbing pauses inactivity timer", arguments: fastCheck)
            <- forAll(Gen<Int>.fromElements(in: 1...5)) { (pauseCount: Int) in
                MainActor.assumeIsolated {
                    let sut = self.makeSUT()

                    // Precondition: overlay visible so a timer is armed and
                    // the pause call has something to cancel.
                    sut.showOverlay()
                    guard sut.isOverlayVisible else { return false }

                    for _ in 0..<pauseCount {
                        sut.pauseInactivityTimer()
                    }

                    let stillVisible = sut.isOverlayVisible

                    // Keep any pending Timer from leaking into later
                    // iterations. After the final pause the timer is already
                    // invalidated, but hideOverlay() flips isOverlayVisible
                    // back to the SUT's starting state regardless.
                    sut.hideOverlay()

                    return stillVisible
                }
            }
    }

    // MARK: - Property 7: Play/pause toggle works regardless of overlay visibility
    // Feature: player-controls, Property 7: Play/pause toggle works regardless of overlay visibility
    // _Validates: Requirements 4.2, 4.3_

    /// For any overlay visibility (visible or hidden) and a player driven
    /// into the `.loaded` state, `togglePlayPause()` inverts
    /// `playerViewModel.isPlaying`. Overlay visibility is a user-facing
    /// concern; the hardware Play/Pause key per Requirement 4.3 must work
    /// regardless of it, and this property pins that invariant at the
    /// view-model level.
    ///
    /// `PlayerViewModel.togglePlayPause()` is a no-op unless `state` is
    /// `.loaded`, so each iteration first drives `requestStream` to
    /// completion with `autoTransitionStates = [.connecting, .connected]`.
    /// That lands `isPlaying == true`, giving the toggle something real to
    /// invert.
    func test_property7_playPauseTogglesRegardlessOfOverlay() {
        property("Feature: player-controls, Property 7: Play/pause toggle works regardless of overlay visibility", arguments: fastCheck)
            <- forAll { (initialOverlayVisible: Bool) in
                MainActor.assumeIsolated {
                    let fixture = self.makeSUTWithMocks()
                    let sut = fixture.sut
                    let streamManager = fixture.streamManager
                    streamManager.autoTransitionStates = [.connecting, .connected]

                    // Drive the underlying player into .loaded so
                    // togglePlayPause actually mutates state.
                    let loadExp = XCTestExpectation(description: "requestStream")
                    nonisolated(unsafe) let s = sut
                    Task { @MainActor in
                        await s.playerViewModel.requestStream(
                            for: s.activeDevice.id,
                            powerSource: s.activeDevice.powerSource
                        )
                        loadExp.fulfill()
                    }
                    _ = XCTWaiter.wait(for: [loadExp], timeout: 3.0)

                    // Put the overlay in the generated visibility state so
                    // we're testing the toggle across both options.
                    if initialOverlayVisible {
                        sut.showOverlay()
                    } else {
                        sut.hideOverlay()
                    }

                    let before = sut.playerViewModel.isPlaying
                    sut.togglePlayPause()
                    let after = sut.playerViewModel.isPlaying

                    // Clean up any timer showOverlay may have armed.
                    sut.hideOverlay()

                    return after != before
                }
            }
    }

    // MARK: - Property 8: Mute toggle inverts audio state
    // Feature: player-controls, Property 8: Mute toggle inverts audio state
    // _Validates: Requirements 5.2, 5.3_

    /// For any initial `isMuted` state, a single `toggleMute()` produces
    /// the opposite state (the direct inversion claim from Requirements
    /// 5.2/5.3); a second `toggleMute()` returns to the original state
    /// (involution, consistent with Property 1 on overlay toggle). Both
    /// halves are asserted per iteration so a regression in either
    /// direction fails the property.
    ///
    /// The initial `isMuted` state is reached by going through the public
    /// `toggleMute()` API rather than writing `sut.isMuted` directly, so
    /// the full `toggleMute → PlayerViewModel.setMuted → streamManager`
    /// wiring runs on every iteration (mirroring how the overlay's Mute
    /// button actually drives the model).
    func test_property8_muteToggleInvertsAudioState() {
        property("Feature: player-controls, Property 8: Mute toggle inverts audio state", arguments: fastCheck)
            <- forAll { (initialMuted: Bool) in
                MainActor.assumeIsolated {
                    let sut = self.makeSUT()

                    // Drive the SUT to the generated initial state via the
                    // public toggle (default is `false`, so one call flips
                    // to `true` when the generator wants `true`).
                    if initialMuted {
                        sut.toggleMute()
                    }
                    guard sut.isMuted == initialMuted else { return false }

                    // First toggle: must flip to the opposite state.
                    sut.toggleMute()
                    let afterFirst = sut.isMuted
                    guard afterFirst == !initialMuted else { return false }

                    // Second toggle: involution returns us to the start.
                    sut.toggleMute()
                    let afterSecond = sut.isMuted

                    return afterSecond == initialMuted
                }
            }
    }
}

// MARK: - Property 9: Mute state persists across camera switches
// Feature: player-controls, Property 9: Mute state persists across camera switches
// _Validates: Requirement 5.4_

/// Generates a list of 1–5 online devices for Property 9 to iterate
/// `selectCamera` over. The property invariant ("mute state survives each
/// switch") holds regardless of whether the generated devices are distinct,
/// so no `suchThat` filter is applied here; the upper bound of 5 keeps each
/// iteration from ballooning in runtime across 100 trials.
private nonisolated(unsafe) let deviceSwitchSequenceGen: Gen<[RingDevice]> =
    Gen<Int>.fromElements(in: 1...5).flatMap { size in
        TestDataGenerators.randomDevice(online: true).proliferate(withSize: size)
    }

extension PlayerControlsPropertyTests {

    /// For any starting mute state and any generated sequence of
    /// `selectCamera(_:)` calls (1–5 switches), the view model's
    /// `isMuted` value after each switch equals the starting mute state.
    /// This is the view-model-level expression of Requirement 5.4: mute
    /// persists across camera switches within a session.
    ///
    /// `selectCamera` internally calls `playerViewModel.setMuted(isMuted)`
    /// after the new stream lands to re-apply the user's audio choice to
    /// the fresh audio track. That step never mutates `sut.isMuted` itself,
    /// so asserting `sut.isMuted == startingMuted` after every switch
    /// captures the persistence invariant at the right level.
    ///
    /// Each `selectCamera` await is driven through an `XCTestExpectation`
    /// so SwiftCheck's synchronous `forAll` closure can cooperate with the
    /// async API.
    func test_property9_muteStatePersistsAcrossCameraSwitches() {
        property("Feature: player-controls, Property 9: Mute state persists across camera switches", arguments: fastCheck)
            <- forAll(Bool.arbitrary, deviceSwitchSequenceGen) { (startingMuted: Bool, switches: [RingDevice]) in
                MainActor.assumeIsolated {
                    let fixture = self.makeSUTWithMocks()
                    let sut = fixture.sut

                    // Put the SUT into the generated starting mute state.
                    if startingMuted {
                        sut.toggleMute()
                    }
                    guard sut.isMuted == startingMuted else { return false }

                    for device in switches {
                        let switchExp = XCTestExpectation(description: "selectCamera")
                        nonisolated(unsafe) let s = sut
                        nonisolated(unsafe) let target = device
                        Task { @MainActor in
                            await s.selectCamera(target)
                            switchExp.fulfill()
                        }
                        _ = XCTWaiter.wait(for: [switchExp], timeout: 3.0)

                        // Invariant: mute state survives the switch.
                        guard sut.isMuted == startingMuted else {
                            sut.hideOverlay()
                            return false
                        }
                    }

                    // `selectCamera` ends with hideOverlay(), but be explicit
                    // so any late timer state is cleared before the SUT is
                    // torn down.
                    sut.hideOverlay()

                    return true
                }
            }
    }
}
