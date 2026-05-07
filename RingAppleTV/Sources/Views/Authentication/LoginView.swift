import SwiftUI

/// Login screen with email/password fields, 2FA support, and focus management.
struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel

    // MARK: - Focus

    enum Field: Hashable {
        case email
        case password
        case showPasswordToggle
        case twoFactorCode
        case loginButton
    }

    @FocusState private var focusedField: Field?
    @State private var showPassword = false

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
                    .onSubmit {
                        focusedField = .password
                    }

                RevealableSecureField(
                    placeholder: "Password",
                    text: $viewModel.password,
                    isRevealed: $showPassword
                )
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .accessibilityLabel(Text("Password"))
                .accessibilityHint(Text("Enter your Ring account password"))
                .onSubmit {
                    focusedField = .showPasswordToggle
                }

                Button {
                    showPassword.toggle()
                } label: {
                    HStack {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                        Text(showPassword ? "Hide Password" : "Show Password")
                            .font(.system(size: Constants.UI.captionSize))
                    }
                }
                .focused($focusedField, equals: .showPasswordToggle)
                .accessibilityLabel(Text(showPassword ? "Hide password" : "Show password"))
                .onSubmit {
                    if viewModel.requiresTwoFactor {
                        focusedField = .twoFactorCode
                    } else {
                        focusedField = .loginButton
                    }
                }

                if viewModel.requiresTwoFactor {
                    TextField("Verification Code", text: $viewModel.twoFactorCode)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .twoFactorCode)
                        .accessibilityLabel(Text("Two-factor verification code"))
                        .accessibilityHint(Text(viewModel.twoFactorMethod == .authenticator
                            ? "Enter the code from your authenticator app"
                            : "Enter the verification code"))
                        .onSubmit {
                            focusedField = .loginButton
                        }
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
                Text(twoFactorPromptMessage)
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.secondary)
                    .accessibilityLabel(Text(twoFactorPromptMessage))
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

    private var twoFactorPromptMessage: String {
        switch viewModel.twoFactorMethod {
        case .authenticator:
            return "Enter the code from your authenticator app."
        case .sms:
            return "A verification code has been sent via SMS."
        case .email:
            return "A verification code has been sent to your email."
        case .unknown:
            return "Enter your two-factor verification code."
        }
    }

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
