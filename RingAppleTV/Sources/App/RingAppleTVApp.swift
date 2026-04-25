import SwiftUI

/// Main entry point for the Ring Apple TV application.
/// Initializes `AppConfiguration` and `ServiceContainer`, then passes
/// the container to `ContentView` for dependency injection.
@main
struct RingAppleTVApp: App {

    @StateObject private var container: ServiceContainer

    init() {
        let config = AppConfiguration()
        _container = StateObject(wrappedValue: ServiceContainer(configuration: config))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(container: container)
        }
    }
}
