import Foundation
import Combine

/// Owns overlay state for the Netflix-style player controls and coordinates
/// with the existing ``PlayerViewModel``, ``DeviceService``, and
/// ``EventService``.
///
/// This is the skeleton established by task 2.1 of the `player-controls`
/// spec. Only state, dependencies, and initialisation live here; action
/// method bodies are filled in by later tasks (2.2 overlay visibility /
/// inactivity timer, 2.3 playback actions, 2.4 mute toggle, 2.5 camera
/// loading and switching).
@MainActor
final class PlayerControlsViewModel: ObservableObject {

    // MARK: - Published State

    /// Whether the controls overlay is currently visible.
    @Published var isOverlayVisible: Bool = false

    /// Whether incoming audio is muted. Persists across camera switches
    /// within a single player session.
    @Published var isMuted: Bool = false

    /// Whether the stream is at the real-time live edge.
    @Published var isAtLiveEdge: Bool = true

    /// Events available on the timeline for the active device, ordered
    /// ascending by time.
    @Published var events: [RingEvent] = []

    /// Index into ``events`` for the current playhead, or `nil` when at
    /// the live edge.
    @Published var currentEventIndex: Int? = nil

    /// Devices available for selection in the camera picker.
    @Published var availableDevices: [RingDevice] = []

    /// The currently active Ring camera driving the player.
    @Published var activeDevice: RingDevice

    /// Whether the camera picker modal is currently presented.
    @Published var isCameraPickerPresented: Bool = false

    // MARK: - Dependencies

    let playerViewModel: PlayerViewModel
    private let deviceService: DeviceService
    private let eventService: EventService

    /// Backing timer for the 5-second inactivity auto-hide. Created by task 2.2.
    private var inactivityTimer: Timer?

    // MARK: - Init

    init(
        playerViewModel: PlayerViewModel,
        deviceService: DeviceService,
        eventService: EventService,
        activeDevice: RingDevice
    ) {
        self.playerViewModel = playerViewModel
        self.deviceService = deviceService
        self.eventService = eventService
        self.activeDevice = activeDevice
    }

    // MARK: - Overlay Visibility & Inactivity Timer

    /// Toggles overlay visibility. Hidden → visible starts the inactivity
    /// timer; visible → hidden invalidates it.
    func toggleOverlay() {
        if isOverlayVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    /// Shows the overlay and (re)starts the inactivity timer.
    func showOverlay() {
        isOverlayVisible = true
        resetInactivityTimer()
    }

    /// Hides the overlay and invalidates the inactivity timer.
    func hideOverlay() {
        isOverlayVisible = false
        invalidateInactivityTimer()
    }

    /// Cancels any pending auto-hide and schedules a fresh
    /// ``PlayerControlsConstants/inactivityTimeout`` countdown. Only has
    /// any effect while the overlay is visible; callers from hidden state
    /// would waste a timer otherwise.
    func resetInactivityTimer() {
        guard isOverlayVisible else { return }
        scheduleInactivityTimer()
    }

    /// Invalidates the inactivity timer without hiding the overlay. Used
    /// while the user is actively scrubbing or interacting with a modal
    /// (e.g. the camera picker) so the overlay won't auto-hide underneath
    /// them.
    func pauseInactivityTimer() {
        invalidateInactivityTimer()
    }

    /// Resumes the inactivity countdown after a pause. No-op when the
    /// overlay is hidden.
    func resumeInactivityTimer() {
        guard isOverlayVisible else { return }
        scheduleInactivityTimer()
    }

    // MARK: - Timer helpers

    /// Invalidates any existing timer and schedules a new one for the
    /// configured inactivity timeout. When it fires, the overlay is
    /// auto-hidden on the main actor.
    private func scheduleInactivityTimer() {
        invalidateInactivityTimer()
        let timer = Timer.scheduledTimer(
            withTimeInterval: PlayerControlsConstants.inactivityTimeout,
            repeats: false
        ) { [weak self] _ in
            // Timer callbacks fire on the run loop's thread (main here,
            // since we scheduled from @MainActor), but the closure isn't
            // isolated. Hop explicitly to the main actor to mutate state.
            Task { @MainActor [weak self] in
                self?.hideOverlay()
            }
        }
        inactivityTimer = timer
    }

    private func invalidateInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    // MARK: - Playback Controls

    /// Toggles the underlying ``PlayerViewModel`` between playing and paused
    /// and resets the inactivity auto-hide countdown.
    ///
    /// Per Requirement 4.3, the hardware Play/Pause key can route into this
    /// method with the overlay hidden; the timer reset is a no-op in that
    /// case because ``resetInactivityTimer`` only schedules while the overlay
    /// is visible.
    func togglePlayPause() {
        playerViewModel.togglePlayPause()
        resetInactivityTimer()
    }

    /// Steps the timeline playhead one event earlier.
    ///
    /// From the live edge, transitions to the most-recent event; from any
    /// event index, moves to the preceding event; at the earliest event,
    /// clamps in place. When the position transitions *away* from live,
    /// `isAtLiveEdge` flips to `false` and `currentEventIndex` is updated
    /// so the view can load the recorded event video. Wiring the actual
    /// recorded-event URL fetch through `EventService` is handled by the
    /// `PlayerView` integration pass (tasks 5.x).
    func skipBack() {
        let next = currentTimelinePosition().movingBack()
        apply(timelinePosition: next)
        resetInactivityTimer()
    }

    /// Steps the timeline playhead one event later.
    ///
    /// At the live edge this is a no-op (Requirement 4.6 — the skip-forward
    /// button is disabled at live). From the most-recent event, the position
    /// transitions to the live edge: `isAtLiveEdge` flips to `true` and
    /// `currentEventIndex` is cleared.
    func skipForward() {
        guard !isAtLiveEdge else { return }
        let next = currentTimelinePosition().movingForward()
        apply(timelinePosition: next)
        resetInactivityTimer()
    }

    /// Jumps playback back to the real-time live edge for the active device.
    ///
    /// Requests a fresh live stream via ``PlayerViewModel/requestStream(for:powerSource:)``
    /// and clears the timeline playhead. `requestStream` is async so the call
    /// is wrapped in a `Task` to keep this method callable from synchronous
    /// button actions in the overlay.
    func jumpToLive() {
        currentEventIndex = nil
        isAtLiveEdge = true
        let deviceId = activeDevice.id
        let powerSource = activeDevice.powerSource
        Task { [playerViewModel] in
            await playerViewModel.requestStream(for: deviceId, powerSource: powerSource)
        }
        resetInactivityTimer()
    }

    // MARK: - Timeline helpers

    /// Constructs a ``TimelinePosition`` from the currently published state so
    /// navigation helpers can delegate bounds logic to the value type.
    private func currentTimelinePosition() -> TimelinePosition {
        TimelinePosition(
            eventIndex: isAtLiveEdge ? nil : currentEventIndex,
            events: events
        )
    }

    /// Mirrors a ``TimelinePosition`` back onto the published `currentEventIndex`
    /// and `isAtLiveEdge` so the UI and `TimelinePosition` stay in sync.
    private func apply(timelinePosition position: TimelinePosition) {
        currentEventIndex = position.eventIndex
        isAtLiveEdge = position.isAtLiveEdge
    }

    // MARK: - Mute Toggle

    /// Inverts the session-scoped mute state and propagates it to the active
    /// transport via ``PlayerViewModel/setMuted(_:)``. That delegate drives
    /// both the WebRTC audio track (through `StreamSessionManager`) and the
    /// HLS/mock `AVPlayer` fallback so the toggle works on every code path.
    ///
    /// Resets the inactivity timer since mute is a user interaction with the
    /// overlay (Requirement 1.4). The `isMuted` value stored on this view
    /// model is independent of `activeDevice`, so the state survives camera
    /// switches — task 2.5 re-applies it inside `selectCamera`.
    func toggleMute() {
        let next = !isMuted
        isMuted = next
        playerViewModel.setMuted(next)
        resetInactivityTimer()
    }

    // MARK: - Camera Loading & Switching

    /// Fetches the online devices available for camera switching and assigns
    /// them to ``availableDevices``.
    ///
    /// Offline devices are filtered out so the picker only lists cameras the
    /// user can actually switch to (Requirement 2.2). Errors are logged and
    /// swallowed per the design's error handling table: a failure leaves
    /// ``availableDevices`` unchanged so the overlay falls back to "no camera
    /// switcher" without disrupting the active stream.
    func loadAvailableDevices() async {
        do {
            let devices = try await deviceService.fetchDevices()
            availableDevices = devices.filter { $0.isOnline }
        } catch {
            // Logged but not surfaced — the camera switcher gracefully hides
            // itself when only the active device is available.
            print("[PlayerControlsViewModel] loadAvailableDevices failed: \(error)")
        }
    }

    /// Switches the player to a different Ring camera.
    ///
    /// Per Requirements 2.3–2.5 and Design State D this tears down the current
    /// stream before starting the new one, so only one WebRTC session is
    /// active at a time. After the new stream is requested, the current
    /// session-scoped mute state is re-applied via
    /// ``PlayerViewModel/setMuted(_:)`` so the toggle survives the switch
    /// (Requirement 5.4), and the overlay hides to get out of the viewer's
    /// way.
    func selectCamera(_ device: RingDevice) async {
        playerViewModel.stopStream()
        activeDevice = device
        await playerViewModel.requestStream(
            for: device.id,
            powerSource: device.powerSource
        )
        // Re-apply mute so the new audio track respects the user's choice.
        // `setMuted` short-circuits when the value is unchanged, but calling
        // it keeps the intent explicit and documents the requirement.
        playerViewModel.setMuted(isMuted)
        hideOverlay()
    }

    /// Fetches recent events for the active device and populates ``events``.
    ///
    /// Overwrites any previously loaded events so the timeline reflects the
    /// currently active camera (Requirement 3.1). Errors are logged and
    /// swallowed — the timeline bar simply renders no markers when the fetch
    /// fails, consistent with the design's error handling table.
    func loadEvents() async {
        do {
            events = try await eventService.fetchEvents(for: activeDevice.id)
        } catch {
            // Logged but not surfaced — the timeline falls back to an empty
            // state and the live indicator remains visible.
            print("[PlayerControlsViewModel] loadEvents failed: \(error)")
        }
    }
}
