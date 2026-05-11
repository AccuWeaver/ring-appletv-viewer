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
    /// Whether audio output is currently muted. Both the WebRTC audio track
    /// (via ``StreamSessionManagerProtocol/setAudioMuted(_:)``) and the
    /// HLS/mock ``AVPlayer`` fallback observe this flag; views that render
    /// the HLS path bind `AVPlayer.isMuted` to this property.
    @Published var isMuted: Bool = false
    #if canImport(WebRTC)
    @Published var videoTrack: RTCVideoTrack?
    #endif

    // MARK: - Dependencies

    let streamSessionManager: StreamSessionManagerProtocol?

    /// Optional services used for the simulator/mock HLS fallback. When the
    /// WebRTC stream manager is unavailable we first try to get a live HLS
    /// feed via the backend's SIP-bridge path, then fall back to the most
    /// recent recorded event for the device, then finally to Apple's BipBop
    /// test stream.
    private let eventService: EventService?
    private let mediaService: MediaService?
    private let simulatorLiveStreamService: SimulatorLiveStreamService?

    // MARK: - Placeholder URLs

    /// Placeholder session URL used when no real WebRTC manager is available
    /// and no live/recorded/fallback URL could be resolved. The view reads
    /// this and substitutes the BipBop test stream.
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
    private var activeHLSBridgeSessionId: String?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        streamSessionManager: StreamSessionManagerProtocol? = nil,
        eventService: EventService? = nil,
        mediaService: MediaService? = nil,
        simulatorLiveStreamService: SimulatorLiveStreamService? = nil
    ) {
        self.streamSessionManager = streamSessionManager
        self.eventService = eventService
        self.mediaService = mediaService
        self.simulatorLiveStreamService = simulatorLiveStreamService
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
                // tvOS simulator, or any platform without WebRTC. Try three
                // fallbacks in order so we show the most-live content the
                // environment can actually render.
                let session = await resolveSimulatorSession(
                    deviceId: deviceId,
                    powerSource: powerSource
                )
                state = .loaded(session)
                isPlaying = true
                return
            }

            try await manager.startStream(deviceId: deviceId, powerSource: powerSource)

            // Create a representative StreamSession for the UI
            let session = StreamSession(
                deviceId: deviceId,
                sessionURL: Self.placeholderLiveSessionURL,
                powerSource: powerSource,
                createdAt: Date(),
                source: .liveWebRTC
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
        // Release the backend-side SIP/HLS session if we allocated one for the
        // simulator live-bridge path. Fire-and-forget — teardown shouldn't
        // block the UI even if the backend is slow.
        if let sessionId = activeHLSBridgeSessionId {
            let service = simulatorLiveStreamService
            Task.detached { [service] in
                await service?.releaseSession(sessionId)
            }
            activeHLSBridgeSessionId = nil
        }
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

    /// Update the mute state and propagate it to the active transport.
    ///
    /// Drives two code paths:
    /// - WebRTC: the current ``StreamSessionManagerProtocol`` is asked to
    ///   enable or disable its audio track so the live stream stays
    ///   connected while silenced.
    /// - HLS / mock fallback: callers observing ``isMuted`` bind it to the
    ///   `AVPlayer.isMuted` property of the HLS player view so the mock
    ///   path also respects the toggle.
    ///
    /// Safe to call before a stream is loaded; the manager stores the
    /// latest request and applies it once a track arrives.
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        streamSessionManager?.setAudioMuted(muted)
    }

    /// Retry the last stream request.
    func retry() async {
        guard let deviceId = lastDeviceId, let powerSource = lastPowerSource else { return }
        await requestStream(for: deviceId, powerSource: powerSource)
    }

    // MARK: - Simulator fallback resolution

    /// How many of the most-recent events to try when resolving a fallback clip URL.
    /// Ring stores recordings only for events covered by an active Ring Protect
    /// subscription, so any given event may 404. We probe a handful to find one
    /// with an actual recording rather than falling back to the test stream too
    /// aggressively.
    private static let maxFallbackEventProbes = 5

    /// Build the StreamSession we hand to the player when WebRTC is unavailable.
    ///
    /// Tries in order:
    /// 1. Live HLS via the backend's SIP-bridge path (real live video on the
    ///    simulator when the unofficial adapter is active).
    /// 2. The most recent recorded event for the device.
    /// 3. A placeholder URL that the view replaces with Apple's BipBop stream.
    ///
    /// The `source` on the returned session tells the view which banner to show.
    private func resolveSimulatorSession(
        deviceId: String,
        powerSource: PowerSource
    ) async -> StreamSession {
        // 1. Live HLS bridge.
        if let live = await tryLiveHLSBridge(deviceId: deviceId) {
            activeHLSBridgeSessionId = live.sessionId
            return StreamSession(
                deviceId: deviceId,
                sessionURL: live.url,
                powerSource: powerSource,
                createdAt: Date(),
                source: .liveHLSBridge,
                backendSessionId: live.sessionId
            )
        }

        // 2. Most recent recorded event.
        if let clipURL = await resolveLatestClipURL(for: deviceId) {
            return StreamSession(
                deviceId: deviceId,
                sessionURL: clipURL,
                powerSource: powerSource,
                createdAt: Date(),
                source: .recordedEvent
            )
        }

        // 3. Placeholder → view renders BipBop.
        return StreamSession(
            deviceId: deviceId,
            sessionURL: Self.placeholderMockSessionURL,
            powerSource: powerSource,
            createdAt: Date(),
            source: .testPattern
        )
    }

    /// Ask the backend to start a live HLS bridge session. Returns `nil` on any
    /// failure so the caller can cleanly fall through to recorded content.
    private func tryLiveHLSBridge(deviceId: String) async -> SimulatorLiveStream? {
        guard let service = simulatorLiveStreamService else { return nil }
        do {
            return try await service.startStream(deviceId: deviceId)
        } catch {
            return nil
        }
    }

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
