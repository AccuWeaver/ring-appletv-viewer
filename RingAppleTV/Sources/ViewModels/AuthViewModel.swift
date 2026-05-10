import Foundation

/// Manages authentication state using a backend-mediated token retrieval flow.
/// Displays setup instructions directing the user to complete authorization
/// in the Ring app, then fetches the token from the partner auth backend.
@MainActor
final class AuthViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<AuthToken> = .idle
    @Published var setupInstructionsVisible: Bool = false

    // MARK: - Dependencies

    private let authService: AuthService

    // MARK: - Computed

    var isAuthenticated: Bool {
        if case .loaded = state {
            return true
        }
        return false
    }

    // MARK: - Init

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Actions

    /// Show setup instructions directing the user to complete authorization in the Ring app.
    func showSetupInstructions() {
        setupInstructionsVisible = true
    }

    /// Check the backend for a valid token after the user indicates they completed setup.
    func checkBackendForToken() async {
        state = .loading

        do {
            let token = try await authService.fetchTokenFromBackend()
            state = .loaded(token)
            setupInstructionsVisible = false
        } catch let error as PartnerAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Log out and reset all state.
    func logout() async {
        await authService.logout()
        state = .idle
        setupInstructionsVisible = false
    }

    /// Check for an existing valid session on launch.
    func checkExistingAuth() async {
        guard authService.isAuthenticated else { return }

        state = .loading
        do {
            let token = try await authService.getValidToken()
            state = .loaded(token)
        } catch {
            state = .idle
        }
    }
}
