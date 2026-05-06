import SwiftUI

/// A password field that supports toggling between masked and revealed text
/// without swapping between `SecureField` and `TextField`, avoiding tvOS focus issues.
///
/// Uses a single `TextField` with a proxy binding to avoid conditional bindings
/// that can stall the Swift type checker.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isRevealed: Bool

    var body: some View {
        TextField(placeholder, text: displayBinding)
            #if os(iOS) || os(tvOS)
            .autocapitalization(.none)
            #endif
            .disableAutocorrection(true)
    }

    /// A single computed binding that either passes through the real text
    /// or presents/reconciles a masked version.
    private var displayBinding: Binding<String> {
        Binding(
            get: {
                isRevealed ? text : String(repeating: "●", count: text.count)
            },
            set: { newValue in
                if isRevealed {
                    text = newValue
                } else {
                    reconcileMaskedInput(newValue)
                }
            }
        )
    }

    /// Figures out what the user actually typed by comparing the new masked
    /// string against the known real password length.
    private func reconcileMaskedInput(_ newMasked: String) {
        let oldCount = text.count
        let newCount = newMasked.count

        if newCount > oldCount {
            let appendedPortion = String(newMasked.dropFirst(oldCount))
            text += appendedPortion
        } else if newCount < oldCount {
            text = String(text.prefix(newCount))
        }
    }
}
