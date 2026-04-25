import SwiftUI

/// Root content view that will handle authentication routing.
/// Displays LoginView when not authenticated, MainTabView when authenticated.
struct ContentView: View {
    var body: some View {
        Text("Ring Camera Viewer")
            .font(.title)
    }
}
