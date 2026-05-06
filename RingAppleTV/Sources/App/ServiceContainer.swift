import Foundation

/// Central dependency container that creates and wires all services and ViewModels.
@MainActor
final class ServiceContainer: ObservableObject {

    // MARK: - Configuration

    let configuration: AppConfiguration

    // MARK: - Infrastructure Services

    let apiClient: PartnerAPIClientProtocol
    let keychainService: KeychainService
    let cacheService: CacheService

    // MARK: - Domain Services

    let authService: AuthService
    let deviceService: DeviceService
    let eventService: EventService
    let mediaService: MediaService
    let streamSessionManager: StreamSessionManagerProtocol?

    // MARK: - Background

    let backgroundRefreshManager: BackgroundRefreshManager

    // MARK: - ViewModels

    let authViewModel: AuthViewModel
    let dashboardViewModel: DashboardViewModel
    let eventsViewModel: EventsViewModel

    // MARK: - Init

    init(configuration: AppConfiguration = AppConfiguration()) {
        self.configuration = configuration

        // 1. Infrastructure
        let partnerAPIClient: PartnerAPIClient
        if configuration.useMocks {
            // In mock mode, point all API calls to the local backend's mock endpoints
            partnerAPIClient = PartnerAPIClient(
                authBaseURL: configuration.authBackendBaseURL,
                apiBaseURL: "\(configuration.authBackendBaseURL)/mock"
            )
        } else {
            partnerAPIClient = PartnerAPIClient()
        }
        let keychainService: KeychainService = DefaultKeychainService()
        let cacheService: CacheService = DefaultCacheService()

        self.apiClient = partnerAPIClient
        self.keychainService = keychainService
        self.cacheService = cacheService

        // 2. Domain services (wired with infrastructure dependencies)
        let authService: AuthService
        if configuration.useMocks {
            // In mock mode, use a simple auth service that always returns a dummy token
            authService = MockAuthService()
        } else {
            authService = BackendAuthService(
                backendBaseURL: configuration.authBackendBaseURL,
                apiKey: configuration.authBackendAPIKey,
                userId: configuration.authBackendUserId,
                keychainService: keychainService
            )
        }
        let deviceService: DeviceService = DefaultDeviceService(
            authService: authService,
            partnerAPIClient: partnerAPIClient,
            cacheService: cacheService
        )
        let eventService: EventService = DefaultEventService(
            authService: authService,
            partnerAPIClient: partnerAPIClient
        )
        let mediaService: MediaService = DefaultMediaService(
            authService: authService,
            partnerAPIClient: partnerAPIClient
        )

        self.authService = authService
        self.deviceService = deviceService
        self.eventService = eventService
        self.mediaService = mediaService

        // Create StreamSessionManager when the WebRTC framework is available.
        // On the tvOS SIMULATOR, video frames don't render through RTCMTLVideoView
        // even though WebRTC connects and receives the track (likely a Metal/decoder
        // issue). On real Apple TV devices WebRTC works correctly.
        // For simulator testing, we fall back to HLS playback via AVPlayer so the UI
        // flow can be validated end-to-end.
        #if canImport(WebRTC) && !targetEnvironment(simulator)
        self.streamSessionManager = StreamSessionManager(
            partnerAPIClient: partnerAPIClient,
            authService: authService
        )
        #else
        self.streamSessionManager = nil
        #endif

        // 3. Background refresh
        self.backgroundRefreshManager = BackgroundRefreshManager(
            deviceService: deviceService,
            mediaService: mediaService
        )

        // 4. ViewModels
        self.authViewModel = AuthViewModel(authService: authService)
        self.dashboardViewModel = DashboardViewModel(
            deviceService: deviceService,
            mediaService: mediaService,
            refreshInterval: configuration.deviceRefreshInterval
        )
        self.eventsViewModel = EventsViewModel(eventService: eventService)
    }

    // MARK: - Factory Methods

    /// Creates a `PlayerViewModel` for a specific streaming session.
    func makePlayerViewModel() -> PlayerViewModel {
        PlayerViewModel(streamSessionManager: streamSessionManager)
    }
}
