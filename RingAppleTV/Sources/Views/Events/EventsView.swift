import SwiftUI

/// Scrollable list of Ring events with navigation to event playback.
/// Shows Ring Protect subscription messaging when applicable.
struct EventsView: View {
    @ObservedObject var viewModel: EventsViewModel

    /// Factory closure to build a PlayerView for event playback.
    let playerViewBuilder: (RingEvent) -> PlayerView

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .idle:
                    Color.clear.onAppear {
                        Task { await viewModel.loadEvents() }
                    }
                case .loading:
                    LoadingView(message: "Loading events…")
                case .loaded(let events):
                    eventList(events)
                case .error(let message):
                    ErrorView(message: message) {
                        Task { await viewModel.refresh() }
                    }
                case .empty(let message):
                    emptyState(message: message)
                }
            }
            .navigationTitle("")
        }
    }

    // MARK: - Event List

    private func eventList(_ events: [RingEvent]) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Ring Protect banner when subscription is inactive
                if !viewModel.hasRingProtect {
                    ringProtectBanner
                }

                ForEach(events) { event in
                    NavigationLink {
                        playerViewBuilder(event)
                    } label: {
                        EventRowView(event: event, device: viewModel.devices[event.deviceId])
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(Constants.UI.gridSpacing)
        }
    }

    // MARK: - Ring Protect Banner

    private var ringProtectBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.slash")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ring Protect Plan")
                    .font(.system(size: Constants.UI.captionSize, weight: .semibold))
                Text("Subscribe to Ring Protect to save and review event recordings.")
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(Constants.UI.cardPadding)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(Constants.UI.cornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Ring Protect subscription required for video recordings"))
    }

    // MARK: - Empty State

    private func emptyState(message: String) -> some View {
        EmptyStateView(
            message: message,
            guidance: viewModel.hasRingProtect
                ? "Events will appear here when your cameras detect activity."
                : "A Ring Protect subscription is required to view event history.",
            iconName: viewModel.hasRingProtect ? "clock" : "shield.slash"
        )
    }
}
