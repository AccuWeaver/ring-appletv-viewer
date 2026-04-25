import SwiftUI

/// A card displaying a Ring device's snapshot, name, status, and battery level.
/// Designed for the dashboard grid with tvOS focus engine support.
struct DeviceCardView: View {
    let device: RingDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Snapshot / placeholder
            snapshotArea

            // Device info
            VStack(alignment: .leading, spacing: 6) {
                Text(device.description)
                    .font(.system(size: Constants.UI.bodySize, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    deviceTypeIcon
                    statusIndicator
                    Spacer()
                    batteryIndicator
                }
            }
            .padding(.horizontal, 4)
        }
        .cardStyle()
        .focusableCard()
        .accessibilityCard(
            label: accessibilityLabelText,
            hint: "Double-click to view live stream"
        )
    }

    // MARK: - Snapshot

    private var snapshotArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius / 2)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(16 / 9, contentMode: .fit)

            Image(systemName: "video.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Device Type Icon

    private var deviceTypeIcon: some View {
        Image(systemName: iconForDeviceType)
            .font(.system(size: Constants.UI.captionSize))
            .foregroundColor(.secondary)
    }

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

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(device.isOnline ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(device.isOnline ? "Online" : "Offline")
                .font(.system(size: Constants.UI.captionSize))
                .foregroundColor(.secondary)
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
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
            }
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
