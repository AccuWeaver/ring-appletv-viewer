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

    // MARK: - Session tracking

    private var lastDeviceId: String?
    private var lastPowerSource: PowerSource?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(streamSessionManager: StreamSessionManagerProtocol? = nil) {
        self.streamSessionManager = streamSessionManager
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
                // No WebRTC stream manager — likely running in mock mode or on a platform
                // without WebRTC support. Transition to .loaded so the view can render a
                // fallback (e.g., HLS playback) instead of showing an error.
                let fallbackSession = StreamSession(
                    deviceId: deviceId,
                    sessionURL: URL(string: "https://mock.local/session")!,
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
                sessionURL: URL(string: "https://api.amazonvision.com/v1/session")!,
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
}
