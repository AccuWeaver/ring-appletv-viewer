import SwiftUI

/// Root content view that handles authentication routing.
/// Shows `LoginView` when not authenticated, `MainTabView` when authenticated.
struct ContentView: View {
    @ObservedObject var container: ServiceContainer

    // Observe authViewModel directly to react to state changes
    @ObservedObject private var authViewModel: AuthViewModel

    init(container: ServiceContainer) {
        self.container = container
        self.authViewModel = container.authViewModel
    }

    var body: some View {
        Group {
            if container.configuration.useMocks || authViewModel.isAuthenticated {
                MainTabView(container: container)
            } else {
                LoginView(viewModel: authViewModel)
            }
        }
        .task {
            if !container.configuration.useMocks {
                await authViewModel.checkExistingAuth()
            }
        }
    }
}
