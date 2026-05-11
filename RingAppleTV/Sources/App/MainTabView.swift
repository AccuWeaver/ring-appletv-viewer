import SwiftUI

/// Tab-based navigation for authenticated users.
/// Provides "Live" (DashboardView) and "Events" (EventsView) tabs.
struct MainTabView: View {
    @ObservedObject var container: ServiceContainer
    @State private var selectedTab: MainTab = .live

    enum MainTab: Hashable {
        case live
        case events
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
                viewModel: container.dashboardViewModel,
                playerViewBuilder: { device, snapshotData in
                    let playerVM = container.makePlayerViewModel()
                    let controlsVM = container.makePlayerControlsViewModel(
                        playerViewModel: playerVM,
                        activeDevice: device
                    )
                    return PlayerView(
                        viewModel: playerVM,
                        controlsViewModel: controlsVM,
                        device: device,
                        snapshotData: snapshotData
                    )
                }
            )
            .tabItem {
                Label("Live", systemImage: "video.fill")
            }
            .tag(MainTab.live)

            EventsView(
                viewModel: container.eventsViewModel,
                playerViewBuilder: { event in
                    let playerVM = container.makePlayerViewModel()
                    let device = RingDevice(
                        id: event.deviceId,
                        name: "Device \(event.deviceId)",
                        model: "unknown",
                        deviceType: .unknown,
                        firmwareVersion: nil,
                        powerSource: .battery,
                        isOnline: true
                    )
                    let controlsVM = container.makePlayerControlsViewModel(
                        playerViewModel: playerVM,
                        activeDevice: device
                    )
                    return PlayerView(
                        viewModel: playerVM,
                        controlsViewModel: controlsVM,
                        device: device,
                        snapshotData: nil
                    )
                }
            )
            .tabItem {
                Label("Events", systemImage: "clock.fill")
            }
            .tag(MainTab.events)
        }
        .background(
            Image("dashboard-background")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
        )
    }
}
