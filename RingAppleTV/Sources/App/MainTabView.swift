import SwiftUI

/// Tab-based navigation for authenticated users.
/// Provides "Live" (DashboardView) and "Events" (EventsView) tabs.
struct MainTabView: View {
    @ObservedObject var container: ServiceContainer
    @State private var selectedTab: Tab = .live

    enum Tab: Hashable {
        case live
        case events
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
                viewModel: container.dashboardViewModel,
                playerViewBuilder: { device, snapshotData in
                    let playerVM = container.makePlayerViewModel()
                    return PlayerView(viewModel: playerVM, device: device, snapshotData: snapshotData)
                }
            )
            .tabItem {
                Label("Live", systemImage: "video.fill")
            }
            .tag(Tab.live)

            EventsView(
                viewModel: container.eventsViewModel,
                playerViewBuilder: { event in
                    let playerVM = container.makePlayerViewModel()
                    let device = RingDevice(
                        id: event.deviceId,
                        description: event.deviceName,
                        deviceType: .unknown,
                        firmwareVersion: nil,
                        address: nil,
                        batteryLife: nil,
                        features: nil,
                        isOnline: true
                    )
                    return PlayerView(viewModel: playerVM, device: device, snapshotData: nil)
                }
            )
            .tabItem {
                Label("Events", systemImage: "clock.fill")
            }
            .tag(Tab.events)
        }
    }
}
