import Foundation
import Combine
#if canImport(WebRTC)
import WebRTC
#endif

/// Manages live stream playback using WHEP + WebRTC via StreamSessionManager.
@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<StreamSession> = .idle
    @Published var isPlaying = false
    @Published var connectionState: WebRTCConnectionState = .disconnected
    #if canImport(WebRTC)
    @Published var videoTrack: RTCVideoTrack?
    #endif

    // MARK: - Dependencies

    let streamSessionManager: StreamSessionManagerProtocol?

    /// Optional services used for the simulator/mock HLS fallback. When the
    /// WebRTC stream manager is unavailable we fetch the most recent recorded
    /// event for the device and surface its playback URL instead of a
    /// hard-coded test stream.
    private let eventService: EventService?
    private let mediaService: MediaService?

    // MARK: - Placeholder URLs

    /// Placeholder session URL used when no real WebRTC manager is available
    /// (mock mode or unsupported platforms). Rendered only as an identifier on
    /// the synthesised `StreamSession` and never dereferenced as a network URL.
    static let placeholderMockSessionURL: URL = {
        guard let url = URL(string: "https://mock.local/session") else {
            fatalError("PlayerViewModel: placeholderMockSessionURL literal is invalid")
        }
        return url
    }()

    /// Placeholder URL reported on the live `StreamSession` surfaced to the UI
    /// so the view can key cache/dedup logic off a stable value. The real WHEP
    /// session URL lives inside the StreamSessionManager and is not exposed.
    static let placeholderLiveSessionURL: URL = {
        guard let url = URL(string: "https://api.amazonvision.com/v1/session") else {
            fatalError("PlayerViewModel: placeholderLiveSessionURL literal is invalid")
        }
        return url
    }()

    // MARK: - Session tracking

    private var lastDeviceId: String?
    private var lastPowerSource: PowerSource?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        streamSessionManager: StreamSessionManagerProtocol? = nil,
        eventService: EventService? = nil,
        mediaService: MediaService? = nil
    ) {
        self.streamSessionManager = streamSessionManager
        self.eventService = eventService
        self.mediaService = mediaService
        subscribeToConnectionState()
    }

    // MARK: - Connection State Subscription

    private func subscribeToConnectionState() {
        guard let manager = streamSessionManager else { return }
        manager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.connectionState = newState
            }
            .store(in: &cancellables)

        #if canImport(WebRTC)
        // Subscribe to the manager's videoTrack publisher so the view re-renders
        // when the track arrives via didAddReceiver.
        if let concreteManager = manager as? StreamSessionManager {
            concreteManager.$videoTrack
                .receive(on: DispatchQueue.main)
                .sink { [weak self] track in
                    self?.videoTrack = track
                }
                .store(in: &cancellables)
        }
        #endif
    }

    // MARK: - Actions

    /// Request a live stream for the given device.
    func requestStream(for deviceId: String, powerSource: PowerSource) async {
        lastDeviceId = deviceId
        lastPowerSource = powerSource
        state = .loading
        isPlaying = false

        do {
            guard let manager = streamSessionManager else {
                // No WebRTC stream manager — running in mock mode, on the
                // tvOS simulator, or any platform without WebRTC. Attempt
                // to resolve the most recent recorded clip for the device
                // so the HLS fallback player shows real footage. If that
                // fails (no events, no Ring Protect, network error) we
                // still transition to .loaded with a placeholder URL; the
                // view falls back to a hard-coded test stream.
                let clipURL = await resolveLatestClipURL(for: deviceId)
                let fallbackSession = StreamSession(
                    deviceId: deviceId,
                    sessionURL: clipURL ?? Self.placeholderMockSessionURL,
                    powerSource: powerSource,
                    createdAt: Date()
                )
                state = .loaded(fallbackSession)
                isPlaying = true
                return
            }

            try await manager.startStream(deviceId: deviceId, powerSource: powerSource)

            // Create a representative StreamSession for the UI
            let session = StreamSession(
                deviceId: deviceId,
                sessionURL: Self.placeholderLiveSessionURL,
                powerSource: powerSource,
                createdAt: Date()
            )
            state = .loaded(session)
            isPlaying = true
        } catch let error as PartnerAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Stop the current stream and release resources.
    func stopStream() {
        Task {
            await streamSessionManager?.stopStream()
        }
        isPlaying = false
    }

    /// Toggle play/pause state.
    func togglePlayPause() {
        guard case .loaded = state else { return }
        isPlaying.toggle()
    }

    /// Retry the last stream request.
    func retry() async {
        guard let deviceId = lastDeviceId, let powerSource = lastPowerSource else { return }
        await requestStream(for: deviceId, powerSource: powerSource)
    }

    // MARK: - Fallback clip resolution

    /// How many of the most-recent events to try when resolving a fallback clip URL.
    /// Ring stores recordings only for events covered by an active Ring Protect
    /// subscription, so any given event may 404. We probe a handful to find one
    /// with an actual recording rather than falling back to the test stream too
    /// aggressively.
    private static let maxFallbackEventProbes = 5

    /// Try to resolve the URL of the device's most recent recorded event so
    /// the HLS fallback player can show real footage instead of a test stream.
    ///
    /// Returns `nil` when there is no event service wired in, no events exist,
    /// or the first `maxFallbackEventProbes` events all fail URL lookup (e.g.
    /// missing Ring Protect recording). Callers should treat `nil` as "use the
    /// hard-coded test stream" so the UI stays useful.
    private func resolveLatestClipURL(for deviceId: String) async -> URL? {
        guard let eventService = eventService else { return nil }
        do {
            let events = try await eventService.fetchEvents(for: deviceId)
            // Probe the most-recent N events. The first one to resolve wins.
            for event in events.prefix(Self.maxFallbackEventProbes) {
                do {
                    return try await eventService.fetchEventVideoURL(for: event)
                } catch {
                    // 404 on this specific event — try the next one.
                    continue
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}
