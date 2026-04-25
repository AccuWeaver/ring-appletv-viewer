import Foundation

/// Manages live stream playback: requesting streams, play/pause, retry, and session tracking.
@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<StreamSession> = .idle
    @Published var isPlaying = false

    // MARK: - Dependencies

    private let videoService: VideoService

    // MARK: - Session tracking

    private var currentSession: StreamSession?
    private var lastDeviceId: Int?

    // MARK: - Init

    init(videoService: VideoService) {
        self.videoService = videoService
    }

    // MARK: - Actions

    /// Request a live stream for the given device.
    func requestStream(for deviceId: Int) async {
        lastDeviceId = deviceId
        state = .loading
        isPlaying = false

        do {
            let session = try await videoService.requestLiveStream(for: deviceId)
            currentSession = session
            state = .loaded(session)
            isPlaying = true
        } catch let error as RingAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Toggle play/pause state.
    func togglePlayPause() {
        guard case .loaded = state else { return }
        isPlaying.toggle()
    }

    /// Retry the last stream request.
    func retry() async {
        guard let deviceId = lastDeviceId else { return }
        await requestStream(for: deviceId)
    }

    /// Check whether the current session is still valid.
    var isSessionValid: Bool {
        guard let session = currentSession else { return false }
        return videoService.validateStreamSession(session)
    }
}
