import SwiftUI

// MARK: - Card Style Modifier

/// Applies a consistent card appearance for device cards on the dashboard.
struct CardStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Constants.UI.cardPadding)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(Constants.UI.cornerRadius)
    }
}

// MARK: - Focusable Card Modifier

/// Adds focus-aware scaling and highlight for tvOS focus engine cards.
struct FocusableCardModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(
                color: isFocused ? Color.blue.opacity(0.4) : Color.clear,
                radius: isFocused ? 12 : 0
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - Accessibility Helpers

/// Combines a label and hint into a single accessibility modifier.
struct AccessibilityCardModifier: ViewModifier {
    let label: String
    let hint: String

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(hint))
    }
}

// MARK: - View Extension

extension View {

    /// Applies the standard card style (padding, background, corner radius).
    func cardStyle() -> some View {
        modifier(CardStyleModifier())
    }

    /// Adds tvOS focus-aware scaling and shadow to a card.
    func focusableCard() -> some View {
        modifier(FocusableCardModifier())
    }

    /// Convenience for setting VoiceOver label and hint together.
    func accessibilityCard(label: String, hint: String) -> some View {
        modifier(AccessibilityCardModifier(label: label, hint: hint))
    }
}
