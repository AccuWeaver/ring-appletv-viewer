import SwiftUI

/// Authentication screen for the backend-mediated token flow.
/// Displays setup instructions directing the user to complete authorization
/// in the Ring app, then fetches the token from the partner auth backend.
struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel

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

            // Content based on state
            Group {
                if viewModel.setupInstructionsVisible {
                    setupInstructionsContent
                } else if case .loading = viewModel.state {
                    LoadingView(message: "Checking for authorization…", style: .inline)
                        .accessibilityLabel(Text("Checking for authorization"))
                } else if case .error(let message) = viewModel.state {
                    errorContent(message: message)
                } else {
                    startSetupContent
                }
            }

            Spacer()
        }
        .padding(Constants.UI.cardPadding * 2)
    }

    // MARK: - Setup Instructions

    private var setupInstructionsContent: some View {
        VStack(spacing: 32) {
            Text("Complete Setup in the Ring App")
                .font(.system(size: Constants.UI.titleSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 16) {
                instructionRow(number: "1", text: "Open the Ring app on your phone")
                instructionRow(number: "2", text: "Go to the Ring AppStore")
                instructionRow(number: "3", text: "Find and install the Ring Camera Viewer app")
                instructionRow(number: "4", text: "Select the devices you want to share")
                instructionRow(number: "5", text: "Complete the authorization")
            }
            .padding(.horizontal, 40)

            // Loading state while checking backend
            if case .loading = viewModel.state {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking for authorization…")
                        .font(.system(size: Constants.UI.captionSize))
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Checking for authorization"))
            }

            // Error message (shown alongside instructions if fetch fails)
            if case .error(let message) = viewModel.state {
                Text(message)
                    .font(.system(size: Constants.UI.captionSize))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .accessibilityLabel(Text("Error: \(message)"))
            }

            Button {
                Task { await viewModel.checkBackendForToken() }
            } label: {
                Text("I've Completed Setup")
                    .font(.system(size: Constants.UI.bodySize, weight: .semibold))
                    .frame(maxWidth: 400)
            }
            .accessibilityLabel(Text("I've completed setup"))
            .accessibilityHint(Text("Double-click to check for your Ring authorization"))
        }
    }

    // MARK: - Instruction Row

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: Constants.UI.bodySize, weight: .bold))
                .foregroundColor(.blue)
                .frame(width: 30)
            Text(text)
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): \(text)"))
    }

    // MARK: - Error Content

    private func errorContent(message: String) -> some View {
        VStack(spacing: 24) {
            Text(message)
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .accessibilityLabel(Text("Error: \(message)"))

            Button {
                Task { await viewModel.checkBackendForToken() }
            } label: {
                Text("Try Again")
                    .font(.system(size: Constants.UI.bodySize, weight: .semibold))
                    .frame(maxWidth: 400)
            }
            .accessibilityLabel(Text("Try again"))
            .accessibilityHint(Text("Double-click to retry checking for authorization"))
        }
    }

    // MARK: - Start Setup

    private var startSetupContent: some View {
        VStack(spacing: 24) {
            Text("Link your Ring account to view your cameras.")
                .font(.system(size: Constants.UI.bodySize))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.showSetupInstructions()
            } label: {
                Text("Get Started")
                    .font(.system(size: Constants.UI.bodySize, weight: .semibold))
                    .frame(maxWidth: 400)
            }
            .accessibilityLabel(Text("Get started"))
            .accessibilityHint(Text("Double-click to see setup instructions"))
        }
    }
}
