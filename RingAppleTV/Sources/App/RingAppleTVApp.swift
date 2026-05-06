import SwiftUI
import BackgroundTasks
#if canImport(WebRTC)
import WebRTC
#endif

/// Main entry point for the Ring Apple TV application.
/// Initializes `AppConfiguration` and `ServiceContainer`, then passes
/// the container to `ContentView` for dependency injection.
/// Registers and schedules background app refresh for snapshot pre-fetching.
@main
struct RingAppleTVApp: App {

    @StateObject private var container: ServiceContainer

    init() {
        // Initialize WebRTC SSL exactly once before any peer connection work.
        // Required by WebRTC — without this, RTCPeerConnectionFactory can assert
        // on internal code paths (especially in the tvOS simulator).
        #if canImport(WebRTC)
        RTCInitializeSSL()
        // Enable maximum logging so we can diagnose device-specific crashes.
        RTCSetMinDebugLogLevel(.verbose)
        #endif

        let config = AppConfiguration()
        let container = ServiceContainer(configuration: config)
        _container = StateObject(wrappedValue: container)

        // Register background refresh task (manager is owned by ServiceContainer)
        container.backgroundRefreshManager.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(container: container)
                .onAppear {
                    container.backgroundRefreshManager.scheduleNextRefresh()
                }
        }
    }
}
