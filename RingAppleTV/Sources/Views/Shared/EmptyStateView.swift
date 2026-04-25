import SwiftUI

/// Displays an empty-state placeholder with an icon, message, and guidance text.
struct EmptyStateView: View {
    let message: String
    let guidance: String?
    let iconName: String

    init(
        message: String,
        guidance: String? = nil,
        iconName: String = "tray"
    ) {
        self.message = message
        self.guidance = guidance
        self.iconName = iconName
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text(message)
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            if let guidance {
                Text(guidance)
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }
}
