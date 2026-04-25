import SwiftUI

/// Displays an error message with an optional retry button.
/// The retry button receives initial focus for quick recovery.
struct ErrorView: View {
    let message: String
    let retryTitle: String
    let onRetry: (() -> Void)?

    @FocusState private var isRetryFocused: Bool

    init(
        message: String,
        retryTitle: String = "Try Again",
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text(message)
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let onRetry {
                Button(action: onRetry) {
                    Text(retryTitle)
                        .font(.system(size: Constants.UI.bodySize))
                }
                .focused($isRetryFocused)
                .accessibilityLabel(Text(retryTitle))
                .accessibilityHint(Text("Double-click to retry the failed operation"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .onAppear {
            isRetryFocused = true
        }
    }
}
