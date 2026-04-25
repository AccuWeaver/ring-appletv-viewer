import SwiftUI

/// Login screen with email/password fields, 2FA support, and focus management.
struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel

    // MARK: - Focus

    enum Field: Hashable {
        case email
        case password
        case twoFactorCode
        case loginButton
    }

    @FocusState private var focusedField: Field?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            // Ring logo / title
            VStack(spacing: 12) {
                Image(systemName: "video.doorbell")
                    .font(.system(size: 72))
                    .foregroundColor(.blue)
                Text("Ring Camera Viewer")
                    .font(.system(size: Constants.UI.largeTitleSize, weight: .bold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Ring Camera Viewer"))

            // Input fields
            VStack(spacing: 24) {
                TextField("Email", text: $viewModel.email)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .email)
                    .accessibilityLabel(Text("Email address"))
                    .accessibilityHint(Text("Enter your Ring account email"))

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel(Text("Password"))
                    .accessibilityHint(Text("Enter your Ring account password"))

                if viewModel.requiresTwoFactor {
                    TextField("Verification Code", text: $viewModel.twoFactorCode)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .twoFactorCode)
                        .accessibilityLabel(Text("Two-factor verification code"))
                        .accessibilityHint(Text("Enter the code sent to your device"))
                }
            }
            .frame(maxWidth: 500)

            // Error message
            if case .error(let message) = viewModel.state {
                Text(message)
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .accessibilityLabel(Text("Error: \(message)"))
            }

            // 2FA prompt
            if viewModel.requiresTwoFactor, case .idle = viewModel.state {
                Text("A verification code has been sent to your device.")
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
                    .accessibilityLabel(Text("A verification code has been sent to your device"))
            }

            // Login button
            loginButton

            Spacer()
        }
        .padding(Constants.UI.cardPadding * 2)
        .onAppear {
            focusedField = .email
        }
    }

    // MARK: - Login Button

    @ViewBuilder
    private var loginButton: some View {
        if case .loading = viewModel.state {
            LoadingView(message: "Signing in…", style: .inline)
                .accessibilityLabel(Text("Signing in"))
        } else {
            Button {
                Task { await viewModel.login() }
            } label: {
                Text(viewModel.requiresTwoFactor ? "Verify" : "Sign In")
                    .font(.system(size: Constants.UI.bodySize, weight: .semibold))
                    .frame(maxWidth: 400)
            }
            .focused($focusedField, equals: .loginButton)
            .disabled(viewModel.email.isEmpty || viewModel.password.isEmpty)
            .accessibilityLabel(Text(viewModel.requiresTwoFactor ? "Verify code" : "Sign in"))
            .accessibilityHint(Text("Double-click to sign in to your Ring account"))
        }
    }
}
