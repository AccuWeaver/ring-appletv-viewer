import SwiftUI

/// Root content view that handles authentication routing.
/// Shows `LoginView` when not authenticated, `MainTabView` when authenticated.
struct ContentView: View {
    @ObservedObject var container: ServiceContainer

    var body: some View {
        Group {
            if container.authViewModel.isAuthenticated {
                MainTabView(container: container)
            } else {
                LoginView(viewModel: container.authViewModel)
            }
        }
        .task {
            await container.authViewModel.checkExistingAuth()
        }
    }
}
