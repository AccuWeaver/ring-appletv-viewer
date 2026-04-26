import SwiftUI

/// A card displaying a Ring device's snapshot, name, and status.
/// Styled to match the native Ring app: snapshot-dominant with overlaid info.
struct DeviceCardView: View {
    let device: RingDevice

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Snapshot / placeholder background
            snapshotArea

            // Overlaid info
            VStack {
                // Top row: status dot + device name + type icon
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.isOnline ? Color.green : Color.red)
                        .frame(width: 10, height: 10)

                    Text(device.description)
                        .font(.system(size: Constants.UI.captionSize, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)

                    Spacer()

                    Image(systemName: iconForDeviceType)
                        .font(.system(size: Constants.UI.captionSize))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Spacer()

                // Bottom row: battery (if available)
                HStack {
                    batteryIndicator
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Constants.UI.cornerRadius))
        .focusableCard()
        .accessibilityCard(
            label: accessibilityLabelText,
            hint: "Double-click to view live stream"
        )
    }

    // MARK: - Snapshot

    private var snapshotArea: some View {
        ZStack {
            // Dark background
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                .fill(Color(white: 0.15))
                .aspectRatio(16 / 9, contentMode: .fit)

            // Gradient overlay for text readability
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 50)

                Spacer()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.5)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 40)
            }

            // Camera icon placeholder (shown when no snapshot)
            if device.snapshotURL == nil {
                Image(systemName: "video.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
    }

    // MARK: - Device Type Icon

    private var iconForDeviceType: String {
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

    // MARK: - Battery

    @ViewBuilder
    private var batteryIndicator: some View {
        if let battery = device.batteryLife {
            HStack(spacing: 4) {
                Image(systemName: batteryIconName(for: battery))
                    .foregroundColor(batteryColor(for: battery))
                Text("\(battery)%")
                    .font(.system(size: Constants.UI.captionSize - 4))
                    .foregroundColor(.white.opacity(0.8))
            }
            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
        }
    }

    private func batteryIconName(for level: Int) -> String {
        switch level {
        case 0..<25: return "battery.25"
        case 25..<50: return "battery.50"
        case 50..<75: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryColor(for level: Int) -> Color {
        level < 20 ? .red : .green
    }

    // MARK: - Accessibility

    private var accessibilityLabelText: String {
        var parts = [device.description, device.deviceType.displayName]
        parts.append(device.isOnline ? "Online" : "Offline")
        if let battery = device.batteryLife {
            parts.append("Battery \(battery) percent")
        }
        return parts.joined(separator: ", ")
    }
}
