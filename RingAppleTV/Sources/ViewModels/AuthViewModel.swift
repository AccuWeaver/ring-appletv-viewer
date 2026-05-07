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
    @Published var twoFactorMethod: TwoFactorMethod = .unknown

    // MARK: - Dependencies

    nonisolated(unsafe) private let authService: AuthService

    // MARK: - Computed

    var isAuthenticated: Bool {
        let authenticated: Bool
        if case .loaded = state {
            authenticated = true
        } else {
            authenticated = false
        }
        print("🔍 [AuthViewModel] isAuthenticated called, returning: \(authenticated)")
        return authenticated
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
                print("🔐 [AuthViewModel] Attempting login with 2FA code")
                token = try await authService.login(
                    email: email,
                    password: password,
                    twoFactorCode: twoFactorCode
                )
                print("✅ [AuthViewModel] 2FA login successful, token received")
            } else {
                print("🔐 [AuthViewModel] Attempting login without 2FA")
                token = try await authService.login(
                    email: email,
                    password: password
                )
                print("✅ [AuthViewModel] Login successful, token received")
            }
            state = .loaded(token)
            requiresTwoFactor = false
            twoFactorCode = ""
            twoFactorMethod = .unknown
            print("✅ [AuthViewModel] State updated to .loaded, requiresTwoFactor = false")
        } catch let error as RingAPIError {
            print("❌ [AuthViewModel] RingAPIError caught: \(error)")
            switch error {
            case .twoFactorRequired(let method):
                print("🔑 [AuthViewModel] 2FA required, method: \(method)")
                requiresTwoFactor = true
                twoFactorMethod = method
                state = .idle
            case .twoFactorInvalid:
                // Stay on the 2FA screen so the user can retry
                print("⚠️ [AuthViewModel] Invalid 2FA code")
                state = .error(error.userMessage)
            default:
                print("❌ [AuthViewModel] Other error: \(error.userMessage)")
                state = .error(error.userMessage)
            }
        } catch {
            print("❌ [AuthViewModel] Unexpected error: \(error.localizedDescription)")
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
        twoFactorMethod = .unknown
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
