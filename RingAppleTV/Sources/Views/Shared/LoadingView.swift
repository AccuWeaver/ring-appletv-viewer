import SwiftUI

/// A configurable loading indicator for use across the app.
/// Supports an optional message and different visual styles.
struct LoadingView: View {
    let message: String?
    let style: Style

    enum Style {
        case standard
        case overlay
        case inline
    }

    init(message: String? = nil, style: Style = .standard) {
        self.message = message
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .standard:
                standardView
            case .overlay:
                overlayView
            case .inline:
                inlineView
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message ?? "Loading"))
    }

    // MARK: - Standard (centered, full area)

    private var standardView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            if let message {
                Text(message)
                    .font(.system(size: Constants.UI.bodySize))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Overlay (dimmed background)

    private var overlayView: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                if let message {
                    Text(message)
                        .font(.system(size: Constants.UI.bodySize))
                        .foregroundColor(.white)
                }
            }
            .padding(Constants.UI.cardPadding * 2)
            .background(Color.black.opacity(0.7))
            .cornerRadius(Constants.UI.cornerRadius)
        }
    }

    // MARK: - Inline (compact, for embedding)

    private var inlineView: some View {
        HStack(spacing: 12) {
            ProgressView()
            if let message {
                Text(message)
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
            }
        }
    }
}
