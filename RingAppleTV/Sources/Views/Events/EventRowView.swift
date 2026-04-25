import SwiftUI

/// A single row in the events list showing event type, timestamp, device name, and thumbnail.
struct EventRowView: View {
    let event: RingEvent

    var body: some View {
        HStack(spacing: 16) {
            // Thumbnail placeholder
            thumbnailArea

            // Event info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: event.eventType.iconName)
                        .font(.system(size: Constants.UI.captionSize))
                        .foregroundColor(iconColor)
                    Text(event.eventType.displayName)
                        .font(.system(size: Constants.UI.bodySize, weight: .medium))
                }

                Text(event.deviceName)
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)

                Text(event.createdAt.relativeTime())
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if event.videoAvailable {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.blue)
                    .accessibilityHidden(true)
            }
        }
        .padding(Constants.UI.cardPadding)
        .focusableCard()
        .accessibilityCard(
            label: accessibilityLabelText,
            hint: event.videoAvailable
                ? "Double-click to play event recording"
                : "No video available for this event"
        )
    }

    // MARK: - Thumbnail

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius / 2)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 120, height: 68)

            Image(systemName: event.eventType.iconName)
                .font(.system(size: 24))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private var iconColor: Color {
        switch event.eventType {
        case .motion: return .orange
        case .ding: return .blue
        case .onDemand: return .green
        }
    }

    private var accessibilityLabelText: String {
        [
            event.eventType.displayName,
            "from \(event.deviceName)",
            event.createdAt.relativeTime()
        ].joined(separator: ", ")
    }
}
