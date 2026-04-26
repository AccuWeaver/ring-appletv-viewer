import Foundation

/// Central dependency container that creates and wires all services and ViewModels.
/// Supports mock vs real API based on `AppConfiguration.useMocks`.
@MainActor
final class ServiceContainer: ObservableObject {

    // MARK: - Configuration

    let configuration: AppConfiguration

    // MARK: - Infrastructure Services

    let apiClient: RingAPIClient
    let keychainService: KeychainService
    let cacheService: CacheService

    // MARK: - Domain Services

    let authService: AuthService
    let deviceService: DeviceService
    let videoService: VideoService
    let eventService: EventService
    let snapshotService: SnapshotService

    // MARK: - ViewModels

    let authViewModel: AuthViewModel
    let dashboardViewModel: DashboardViewModel
    let eventsViewModel: EventsViewModel

    // MARK: - Init

    init(configuration: AppConfiguration = AppConfiguration()) {
        self.configuration = configuration

        // 1. Infrastructure
        let apiClient: RingAPIClient = DefaultRingAPIClient()
        let keychainService: KeychainService = DefaultKeychainService()
        let cacheService: CacheService = DefaultCacheService()

        self.apiClient = apiClient
        self.keychainService = keychainService
        self.cacheService = cacheService

        // 2. Domain services (wired with infrastructure dependencies)
        let authService: AuthService = DefaultAuthService(
            apiClient: apiClient,
            keychainService: keychainService
        )
        let deviceService: DeviceService = DefaultDeviceService(
            authService: authService,
            apiClient: apiClient,
            cacheService: cacheService
        )
        let videoService: VideoService = DefaultVideoService(
            authService: authService,
            apiClient: apiClient
        )
        let eventService: EventService = DefaultEventService(
            authService: authService,
            apiClient: apiClient
        )
        let snapshotService: SnapshotService = DefaultSnapshotService(
            authService: authService,
            apiClient: apiClient
        )

        self.authService = authService
        self.deviceService = deviceService
        self.videoService = videoService
        self.eventService = eventService
        self.snapshotService = snapshotService

        // 3. ViewModels
        self.authViewModel = AuthViewModel(authService: authService)
        self.dashboardViewModel = DashboardViewModel(
            deviceService: deviceService,
            snapshotService: snapshotService,
            refreshInterval: configuration.deviceRefreshInterval
        )
        self.eventsViewModel = EventsViewModel(eventService: eventService)
    }

    // MARK: - Factory Methods

    /// Creates a `PlayerViewModel` for a specific streaming session.
    func makePlayerViewModel() -> PlayerViewModel {
        PlayerViewModel(videoService: videoService)
    }
}
