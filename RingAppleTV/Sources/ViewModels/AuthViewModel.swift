import Foundation

/// Manages authentication state, login/logout flows, and 2FA handling.
@MainActor
final class AuthViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<AuthToken> = .idle
    @Published var email = ""
    @Published var password = ""
    @Published var twoFactorCode = ""
    @Published var requiresTwoFactor = false

    // MARK: - Dependencies

    private let authService: AuthService

    // MARK: - Computed

    var isAuthenticated: Bool {
        if case .loaded = state { return true }
        return false
    }

    // MARK: - Init

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Actions

    /// Attempt login with current email/password (and optional 2FA code).
    func login() async {
        state = .loading

        do {
            let token: AuthToken
            if requiresTwoFactor {
                token = try await authService.login(
                    email: email,
                    password: password,
                    twoFactorCode: twoFactorCode
                )
            } else {
                token = try await authService.login(
                    email: email,
                    password: password
                )
            }
            state = .loaded(token)
            requiresTwoFactor = false
            twoFactorCode = ""
        } catch let error as RingAPIError where error == .twoFactorRequired {
            requiresTwoFactor = true
            state = .idle
        } catch let error as RingAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Log out and reset all state.
    func logout() async {
        await authService.logout()
        state = .idle
        email = ""
        password = ""
        twoFactorCode = ""
        requiresTwoFactor = false
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
