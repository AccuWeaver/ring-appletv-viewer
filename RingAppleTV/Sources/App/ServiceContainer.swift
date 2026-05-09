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
    let simulatorLiveStreamService: SimulatorLiveStreamService?

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
        let infra = Self.makeInfrastructure(configuration: configuration)
        self.apiClient = infra.apiClient
        self.keychainService = infra.keychainService
        self.cacheService = infra.cacheService

        // 2. Domain services (wired with infrastructure dependencies)
        let domain = Self.makeDomainServices(
            configuration: configuration,
            apiClient: infra.apiClient,
            keychainService: infra.keychainService,
            cacheService: infra.cacheService
        )
        self.authService = domain.authService
        self.deviceService = domain.deviceService
        self.eventService = domain.eventService
        self.mediaService = domain.mediaService

        // Create StreamSessionManager when the WebRTC framework is available.
        // On the tvOS SIMULATOR, video frames don't render through RTCMTLVideoView
        // even though WebRTC connects and receives the track (likely a Metal/decoder
        // issue). On real Apple TV devices WebRTC works correctly.
        // For simulator testing, we fall back to HLS playback via AVPlayer so the UI
        // flow can be validated end-to-end.
        #if canImport(WebRTC) && !targetEnvironment(simulator)
        self.streamSessionManager = StreamSessionManager(
            partnerAPIClient: infra.apiClient,
            authService: domain.authService
        )
        // Real Apple TV uses WebRTC; the simulator-only HLS bridge isn't needed.
        self.simulatorLiveStreamService = nil
        #else
        self.streamSessionManager = nil
        // On the simulator we try to route the live feed through the backend's
        // SIP bridge + mediamtx so the player shows real live video via HLS.
        // Only makes sense when we're pointed at our local backend (mock mode
        // covers that; a real partner-API deployment won't expose /mock/*).
        if configuration.useMocks {
            self.simulatorLiveStreamService = DefaultSimulatorLiveStreamService(
                backendBaseURL: configuration.authBackendBaseURL
            )
        } else {
            self.simulatorLiveStreamService = nil
        }
        #endif

        // 3. Background refresh
        self.backgroundRefreshManager = BackgroundRefreshManager(
            deviceService: domain.deviceService,
            mediaService: domain.mediaService
        )

        // 4. ViewModels
        self.authViewModel = AuthViewModel(authService: domain.authService)
        self.dashboardViewModel = DashboardViewModel(
            deviceService: domain.deviceService,
            mediaService: domain.mediaService,
            refreshInterval: configuration.deviceRefreshInterval
        )
        self.eventsViewModel = EventsViewModel(eventService: domain.eventService, deviceService: domain.deviceService)
    }

    // MARK: - Factory Methods

    /// Creates a `PlayerViewModel` for a specific streaming session.
    func makePlayerViewModel() -> PlayerViewModel {
        PlayerViewModel(
            streamSessionManager: streamSessionManager,
            eventService: eventService,
            mediaService: mediaService,
            simulatorLiveStreamService: simulatorLiveStreamService
        )
    }

    // MARK: - Private Construction Helpers

    private struct Infrastructure {
        let apiClient: PartnerAPIClient
        let keychainService: KeychainService
        let cacheService: CacheService
    }

    private struct DomainServices {
        let authService: AuthService
        let deviceService: DeviceService
        let eventService: EventService
        let mediaService: MediaService
    }

    private static func makeInfrastructure(configuration: AppConfiguration) -> Infrastructure {
        let partnerAPIClient: PartnerAPIClient
        if configuration.useMocks {
            // In mock mode, point all API calls to the local backend's mock endpoints.
            partnerAPIClient = PartnerAPIClient(
                authBaseURL: configuration.authBackendBaseURL,
                apiBaseURL: "\(configuration.authBackendBaseURL)/mock"
            )
        } else {
            partnerAPIClient = PartnerAPIClient()
        }
        return Infrastructure(
            apiClient: partnerAPIClient,
            keychainService: DefaultKeychainService(),
            cacheService: DefaultCacheService()
        )
    }

    private static func makeDomainServices(
        configuration: AppConfiguration,
        apiClient: PartnerAPIClient,
        keychainService: KeychainService,
        cacheService: CacheService
    ) -> DomainServices {
        let authService: AuthService
        if configuration.useMocks {
            // In mock mode, use a simple auth service that always returns a dummy token.
            authService = MockAuthService()
        } else {
            authService = BackendAuthService(
                backendBaseURL: configuration.authBackendBaseURL,
                apiKey: configuration.authBackendAPIKey,
                userId: configuration.authBackendUserId,
                keychainService: keychainService
            )
        }
        // Build deviceService once so it can be shared with eventService's
        // "all devices" aggregation path.
        let deviceService = DefaultDeviceService(
            authService: authService,
            partnerAPIClient: apiClient,
            cacheService: cacheService
        )
        return DomainServices(
            authService: authService,
            deviceService: deviceService,
            eventService: DefaultEventService(
                authService: authService,
                partnerAPIClient: apiClient,
                deviceService: deviceService
            ),
            mediaService: DefaultMediaService(
                authService: authService,
                partnerAPIClient: apiClient
            )
        )
    }
}
