import SwiftUI

/// Main dashboard showing a grid of Ring devices with live snapshot thumbnails.
/// Supports pull-to-refresh, loading/empty/error states, and navigation to the player.
struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel

    /// Factory closure to build a PlayerView for a given device.
    /// Injected so the dashboard doesn't need to know about PlayerViewModel's dependencies.
    let playerViewBuilder: (RingDevice, Data?) -> PlayerView

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Constants.UI.gridSpacing),
        count: Constants.UI.gridColumns
    )

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .idle:
                    Color.clear.onAppear {
                        Task { await viewModel.loadDevices() }
                    }
                case .loading:
                    LoadingView(message: "Loading cameras…")
                case .loaded(let devices):
                    deviceGrid(devices)
                case .error(let message):
                    ErrorView(message: message) {
                        Task { await viewModel.refresh() }
                    }
                case .empty(let message):
                    EmptyStateView(
                        message: message,
                        guidance: "Make sure your Ring devices are set up and online.",
                        iconName: "video.slash"
                    )
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("Refresh"))
                    .accessibilityHint(Text("Double-click to refresh the device list"))
                }
            }
        }
        .onDisappear {
            viewModel.stopBackgroundRefresh()
        }
    }

    // MARK: - Device Grid

    private func deviceGrid(_ devices: [RingDevice]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Constants.UI.gridSpacing) {
                ForEach(devices) { device in
                    NavigationLink {
                        playerViewBuilder(device, viewModel.snapshots[device.id])
                    } label: {
                        DeviceCardView(device: device, snapshotData: viewModel.snapshots[device.id])
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, Constants.UI.gridSpacing)
            .padding(.bottom, Constants.UI.gridSpacing)
        }
    }
}
