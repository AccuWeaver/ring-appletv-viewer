import SwiftUI
import BackgroundTasks

/// Main entry point for the Ring Apple TV application.
/// Initializes `AppConfiguration` and `ServiceContainer`, then passes
/// the container to `ContentView` for dependency injection.
/// Registers and schedules background app refresh for snapshot pre-fetching.
@main
struct RingAppleTVApp: App {

    @StateObject private var container: ServiceContainer
    private let backgroundRefreshManager: BackgroundRefreshManager

    init() {
        let config = AppConfiguration()
        let container = ServiceContainer(configuration: config)
        _container = StateObject(wrappedValue: container)

        let manager = BackgroundRefreshManager(
            deviceService: container.deviceService,
            snapshotService: container.snapshotService
        )
        manager.registerBackgroundTask()
        self.backgroundRefreshManager = manager
    }

    var body: some Scene {
        WindowGroup {
            ContentView(container: container)
                .onAppear {
                    backgroundRefreshManager.scheduleNextRefresh()
                }
        }
    }
}
