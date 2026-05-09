import SwiftUI

/// A single row in the events list showing event type, timestamp, and device info.
struct EventRowView: View {
    let event: RingEvent
    var device: RingDevice?

    var body: some View {
        HStack(spacing: 16) {
            // Event info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: event.eventType.iconName)
                        .font(.system(size: Constants.UI.captionSize))
                        .foregroundColor(iconColor)
                    Text(event.eventType.displayName)
                        .font(.system(size: Constants.UI.bodySize, weight: .medium))
                }

                HStack(spacing: 6) {
                    Image(systemName: deviceTypeIcon)
                        .font(.system(size: Constants.UI.captionSize - 4))
                        .foregroundColor(.secondary)
                    Text(device?.name ?? "Device \(event.deviceId)")
                        .font(.system(size: Constants.UI.captionSize))
                        .foregroundColor(.secondary)
                }

                Text(event.createdAt.relativeTime())
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.blue)
                .accessibilityHidden(true)
        }
        .padding(Constants.UI.cardPadding)
        .background(Color(white: 0.15))
        .cornerRadius(Constants.UI.cornerRadius)
        .focusableCard()
        .accessibilityCard(
            label: accessibilityLabelText,
            hint: "Double-click to play event recording"
        )
    }

    // MARK: - Helpers

    private var deviceTypeIcon: String {
        guard let device else { return "camera.fill" }
        switch device.deviceType {
        case .doorbell, .doorbellPro, .doorbellV2:
            return "video.doorbell"
        case .stickupCam, .spotlightCam, .floodlightCam:
            return "web.camera.fill"
        case .indoorCam:
            return "web.camera"
        case .unknown:
            return "camera.fill"
        }
    }

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
            "from device \(event.deviceId)",
            event.createdAt.relativeTime()
        ].joined(separator: ", ")
    }
}
