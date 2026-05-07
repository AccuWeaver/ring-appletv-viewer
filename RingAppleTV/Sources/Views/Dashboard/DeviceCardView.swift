import SwiftUI

/// A card displaying a Ring device's snapshot, name, and status.
/// Styled to match the native Ring app: snapshot-dominant with overlaid info.
struct DeviceCardView: View {
    let device: RingDevice
    let snapshotData: Data?

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

                    Text(device.name)
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

                // Bottom row: power source indicator
                HStack {
                    powerSourceIndicator
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

            // Snapshot image when available
            #if canImport(UIKit)
            if let snapshotData, let uiImage = UIImage(data: snapshotData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholderIcon
            }
            #elseif canImport(AppKit)
            if let snapshotData, let nsImage = NSImage(data: snapshotData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholderIcon
            }
            #else
            placeholderIcon
            #endif

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
        }
    }

    private var placeholderIcon: some View {
        // Camera icon placeholder (shown when no snapshot)
        Image(systemName: "video.fill")
            .font(.system(size: 36))
            .foregroundColor(.gray.opacity(0.5))
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

    // MARK: - Power Source

    @ViewBuilder
    private var powerSourceIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: device.powerSource == .battery ? "battery.50" : "powerplug.fill")
                .foregroundColor(device.powerSource == .battery ? .yellow : .green)
            Text(device.powerSource == .battery ? "Battery" : "Wired")
                .font(.system(size: Constants.UI.captionSize - 4))
                .foregroundColor(.white.opacity(0.8))
        }
        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
    }

    // MARK: - Accessibility

    private var accessibilityLabelText: String {
        var parts = [device.name, device.deviceType.displayName]
        parts.append(device.isOnline ? "Online" : "Offline")
        parts.append(device.powerSource == .battery ? "Battery powered" : "Line powered")
        return parts.joined(separator: ", ")
    }
}
