import AppKit
import Foundation
import Security
import SwiftUI

private struct NativeSavedAccountProfile: Codable, Identifiable, Equatable {
    let id: String
    let token: String
    let lastUsedAt: Date
}

private enum NativeSavedAccountProfiles {
    private static let service = "com.hanasand.desktop.saved-account-profiles"
    private static let account = "profiles-v1"
    private static let maximumProfiles = 20

    static func read() throws -> [NativeSavedAccountProfile] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DesktopCredentialStoreError.keychain(status)
        }
        return try JSONDecoder().decode([NativeSavedAccountProfile].self, from: data)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(maximumProfiles)
            .map { $0 }
    }

    static func save(_ profile: NativeSavedAccountProfile) throws {
        var profiles = try read().filter { $0.id != profile.id }
        profiles.insert(profile, at: 0)
        try write(Array(profiles.prefix(maximumProfiles)))
    }

    static func removeAll() throws { try write([]) }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func write(_ profiles: [NativeSavedAccountProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DesktopCredentialStoreError.keychain(status) }
        var insert = baseQuery
        attributes.forEach { insert[$0.key] = $0.value }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw DesktopCredentialStoreError.keychain(addStatus) }
    }
}

private enum NativeAccountRouteKind: Equatable {
    case login
    case signup
    case logout
    case secureAccount
    case switchAccount
    case resetPassword
    case resetPasswordAgain
    case pendingDeletion
    case loadTest(String?)
    case upload

    init?(path: String) {
        switch path {
        case "/login": self = .login
        case "/signup", "/register": self = .signup
        case "/logout": self = .logout
        case "/secure-account": self = .secureAccount
        case "/switch-account": self = .switchAccount
        case "/reset-password": self = .resetPassword
        case "/reset-password-again": self = .resetPasswordAgain
        case "/account-pending-deletion": self = .pendingDeletion
        case "/upload": self = .upload
        case "/test": self = .loadTest(nil)
        default:
            guard let route = LoadTestingPublicRoute(path: path) else { return nil }
            self = .loadTest(route.testID)
        }
    }

    var title: String {
        switch self {
        case .login: "Sign in to Hanasand"
        case .signup: "Create your Hanasand account"
        case .logout: "Sign out"
        case .secureAccount: "Secure your account"
        case .switchAccount: "Switch account"
        case .resetPassword, .resetPasswordAgain: "Reset your password"
        case .pendingDeletion: "Restore your account"
        case .loadTest: "Check a service"
        case .upload: "Upload public media"
        }
    }
}

private struct NativeTokenActionResponse: Decodable {
    let error: String?
}

private struct NativePasswordResetAgainResponse: Decodable {
    let error: String?
    let id: String
    let resetToken: String
}

private final class NativeAccountRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum NativeAccountRouteSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NativeAccountRedirectBlocker(), delegateQueue: nil)
    }()
}

struct NativeAccountRoutePanel: View {
    let path: String
    let query: [String: String]

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var message = ""
    @State private var isBusy = false
    @State private var routePrepared = false
    @State private var preparedTaskIdentity = ""
    @State private var actionToken = ""
    @State private var resetUserID = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var locked = false
    @State private var restored = false
    @State private var resetCompleted = false
    @State private var signupName = ""
    @State private var signupUsername = ""
    @State private var signupEmail = ""
    @State private var signupPassword = ""
    @State private var signupChallengeID: String?
    @State private var signupCode = ""
    @State private var signupWaitingForCode = false
    @State private var isResendingSignupCode = false
    @State private var savedProfiles: [NativeSavedAccountProfile] = []
    @State private var profilesError = ""
    @State private var addingProfile = false

    private var kind: NativeAccountRouteKind? {
        if path == "/login", query["mode"]?.lowercased() == "signup" { return .signup }
        return NativeAccountRouteKind(path: path)
    }
    private var title: String { kind?.title ?? "Hanasand account" }

    static func supports(path: String) -> Bool { NativeAccountRouteKind(path: path) != nil }

    private var taskIdentity: String {
        let values = [path, query["id"] ?? "", query["username"] ?? "", query["mode"] ?? ""]
        return values.joined(separator: "|")
    }

    private var routeSecretValue: String { query["token"] ?? query["restoreToken"] ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NativeGroupPanel(title: title, subtitle: subtitle) {
                    routeContent
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(message.lowercased().contains("could not") || message.lowercased().contains("unable") ? theme.danger : theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task(id: taskIdentity) { await prepareRoute() }
        .onChange(of: routeSecretValue) { _, value in
            guard !value.isEmpty else { return }
            preparedTaskIdentity = ""
            Task { await prepareRoute() }
        }
    }

    private var subtitle: String {
        switch kind {
        case .login: "Use your Hanasand credentials or a connected sign-in provider."
        case .signup: "Create and verify a Hanasand account."
        case .logout: "End the current Hanasand session."
        case .secureAccount: "Lock sign-in after an unrecognized password change."
        case .switchAccount: "Choose a Keychain-saved session or sign in to another account."
        case .resetPassword, .resetPasswordAgain: "Use the secure reset link to set a new password."
        case .pendingDeletion: "Restore an account scheduled for deletion."
        case .loadTest: "Run a permission-reviewed service check or open a shared result."
        case .upload: "Review a file and publish it to the public CDN."
        case nil: "Account route is unavailable."
        }
    }

    @ViewBuilder private var routeContent: some View {
        switch kind {
        case .login: loginContent
        case .signup: signupContent
        case .logout: logoutContent
        case .secureAccount: secureAccountContent
        case .switchAccount: switchAccountContent
        case .resetPassword: resetPasswordContent
        case .resetPasswordAgain: resetPasswordAgainContent
        case .pendingDeletion: pendingDeletionContent
        case .loadTest(let routeTestID):
            VStack(alignment: .leading, spacing: 12) {
                ActionButton(title: model.hasHanasandAuth ? "Back to dashboard" : "Back to sign in", icon: "arrow.left") {
                    model.closeNativeDashboardPage()
                }
                RecentTestsNativePanel(initialTestID: routeTestID ?? (model.selectedNativeDashboardDetailID.isEmpty ? nil : model.selectedNativeDashboardDetailID))
            }
        case .upload:
            VStack(alignment: .leading, spacing: 12) {
                ActionButton(title: model.hasHanasandAuth ? "Back to dashboard" : "Back to sign in", icon: "arrow.left") {
                    model.closeNativeDashboardPage()
                }
                UploadNativePanel()
            }
        case nil: NativeEmptyState(title: "Account route unavailable", message: "Return to the dashboard and open a supported account page.")
        }
    }

    @ViewBuilder private var loginContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.pendingDeletionUserID.isEmpty {
                pendingDeletionContent
            } else if !model.hasHanasandAuth, model.passwordResetStep == .code {
                recoveryCodeContent
            } else if !model.hasHanasandAuth, model.passwordResetStep == .newPassword {
                resetPasswordContent
            } else if model.hasHanasandAuth {
                Text("You are signed in as @\(model.userIDForRequests).")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text)
                continueButton
            } else {
                TextField("Username", text: $model.loginUsername)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                SecureField("Password", text: $model.loginPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await signIn() } }
                HStack(spacing: 8) {
                    ActionButton(title: model.isLoggingIn ? "Signing in…" : "Sign in", icon: "person.crop.circle") { Task { await signIn() } }
                        .disabled(model.isLoggingIn || model.loginUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.loginPassword.isEmpty)
                    ActionButton(title: "Create account", icon: "person.badge.plus") { openRoute("/signup", label: "Create account", query: filteredReturnQuery) }
                        .disabled(model.isLoggingIn)
                }
                HStack(spacing: 8) {
                    ActionButton(title: "Continue with Google", icon: "globe") { Task { await model.beginGoogleSignIn() } }.disabled(model.isLoggingIn)
                    ActionButton(title: "Continue with SSO", icon: "person.badge.key") { model.beginHanasandSso() }.disabled(model.isLoggingIn)
                }
                ActionButton(title: "Forgot password?", icon: "key") {
                    model.loginUsername = model.loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.beginPasswordReset()
                    message = "Enter your username and use the recovery form on the sign-in screen."
                }
                .disabled(model.isLoggingIn)
                if !model.loginStatus.isEmpty {
                    Text(model.loginStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var recoveryCodeContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Enter your username and request a one-time reset code.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            TextField("Username", text: $model.passwordResetUsername).textFieldStyle(.roundedBorder)
            ActionButton(title: model.isResettingPassword ? "Sending…" : "Send code", icon: "envelope") { Task { await model.requestPasswordResetCode() } }
                .disabled(model.isResettingPassword)
            TextField("Six-digit code", text: Binding(get: { model.passwordResetCode }, set: { model.updatePasswordResetCode($0) }))
                .textFieldStyle(.roundedBorder)
            if !model.passwordResetStatus.isEmpty {
                Text(model.passwordResetStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ActionButton(title: "Back to sign in", icon: "arrow.left") { model.cancelPasswordReset() }
        }
    }

    private var signupContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.hasHanasandAuth {
                Text("You are already signed in as @\(model.userIDForRequests). Sign out or switch accounts before creating another profile.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Switch account", icon: "person.2") { openRoute("/switch-account", label: "Switch account") }
            } else {
                TextField("Full name", text: $signupName).textFieldStyle(.roundedBorder)
                TextField("Username", text: $signupUsername).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                if signupUsernameIsReserved {
                    Text("This username is reserved.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.danger)
                }
                TextField("Email address", text: $signupEmail).textFieldStyle(.roundedBorder).textContentType(.emailAddress).autocorrectionDisabled()
                SecureField("Password", text: $signupPassword).textFieldStyle(.roundedBorder)
                Text("Use at least 16 characters with an uppercase letter, lowercase letter, number, and symbol.")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                if signupWaitingForCode {
                    TextField("Six-digit email code", text: $signupCode)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: signupCode) { _, value in signupCode = String(value.filter(\.isNumber).prefix(6)) }
                    Text("The code expires after 10 minutes. Keep the same signup details while you verify.")
                        .font(.system(size: 10)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    signupActionButtons(vertical: false)
                    signupActionButtons(vertical: true)
                }
                ActionButton(title: "Back to sign in", icon: "arrow.left") { openRoute("/login", label: "Sign in", query: filteredReturnQuery) }
            }
        }
    }

    private var logoutContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.hasHanasandAuth ? "Sign out @\(model.userIDForRequests) from this Desktop session and revoke its Hanasand sessions?" : "This Desktop session is already signed out.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            if !routePrepared {
                ActionButton(title: isBusy ? "Signing out…" : "Sign out", icon: "rectangle.portrait.and.arrow.right") { Task { await signOut() } }
                    .disabled(isBusy)
            } else {
                continueButton
            }
        }
    }

    private var secureAccountContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(locked
                 ? "Your account has been locked. Reset your password before signing in again."
                 : "This will sign out all devices and block sign-ins until you reset your password.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if locked {
                ActionButton(title: "Go to sign in", icon: "arrow.right") { openRoute("/login", label: "Sign in") }
            } else if actionToken.isEmpty {
                NativeEmptyState(title: "Security link missing or expired", message: "Open the secure-account link from your email or start a password reset from sign in.")
                ActionButton(title: "Back to sign in", icon: "arrow.left") { openRoute("/login", label: "Sign in") }
            } else {
                ActionButton(title: isBusy ? "Locking account…" : "Lock account", icon: "lock.shield") { Task { await lockAccount() } }
                    .disabled(isBusy)
            }
        }
    }

    private var switchAccountContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if addingProfile {
                loginContent
                ActionButton(title: "Back to switch accounts", icon: "arrow.left") { addingProfile = false }
            } else {
                Text(model.hasHanasandAuth ? "Currently signed in: @\(model.userIDForRequests)" : "No account is currently signed in.")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                if !profilesError.isEmpty { NativeNotice(message: profilesError) }
                if savedProfiles.isEmpty {
                    NativeEmptyState(title: "No saved profiles", message: "Add a profile to save this session in Keychain for later switching.")
                } else {
                    ForEach(savedProfiles) { profile in
                        Button { Task { await switchTo(profile) } } label: {
                            HStack(spacing: 9) {
                                Image(systemName: profile.id == model.userIDForRequests ? "person.crop.circle.fill" : "person.crop.circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.id == model.userIDForRequests ? "@\(profile.id) · Current account" : "@\(profile.id)")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(profile.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                if profile.id != model.userIDForRequests { Image(systemName: "arrow.right") }
                            }
                            .foregroundStyle(theme.text)
                            .padding(10)
                            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy || profile.id == model.userIDForRequests)
                    }
                }
                HStack(spacing: 8) {
                    ActionButton(title: "Add profile", icon: "person.badge.plus") { Task { await beginAddingProfile() } }.disabled(isBusy)
                    ActionButton(title: "Forget saved profiles", icon: "trash") { Task { await forgetProfiles() } }.disabled(isBusy || savedProfiles.isEmpty)
                }
            }
        }
    }

    private var resetPasswordContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if resetCompleted {
                Text(message.isEmpty ? "Password updated. Sign in with your new password." : message)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Go to sign in", icon: "arrow.right") { openRoute("/login", label: "Sign in") }
            } else if model.passwordResetStep == .newPassword, !model.passwordResetToken.isEmpty {
                Text("Choose a new password for @\(model.passwordResetUsername).")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                SecureField("New password", text: $model.passwordResetNewPassword).textFieldStyle(.roundedBorder)
                SecureField("Confirm new password", text: $model.passwordResetConfirmPassword).textFieldStyle(.roundedBorder)
                ActionButton(title: model.isResettingPassword ? "Saving…" : "Set password", icon: "key") { Task { await completePasswordReset() } }
                    .disabled(model.isResettingPassword || model.passwordResetNewPassword.isEmpty || model.passwordResetConfirmPassword.isEmpty)
                if model.passwordResetStatus.localizedCaseInsensitiveContains("reset") {
                    ActionButton(title: "Go to sign in", icon: "arrow.right") { openRoute("/login", label: "Sign in") }
                }
            } else {
                NativeEmptyState(title: "Reset link missing or expired", message: "Request a new code from the native sign-in screen.")
                ActionButton(title: "Back to sign in", icon: "arrow.left") { openRoute("/login", label: "Sign in") }
            }
        }
    }

    private var resetPasswordAgainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a new password reset and choose a different password.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            if actionToken.isEmpty {
                NativeEmptyState(title: "Reset link missing or expired", message: "Open the reset-again link from your email or request a new code from sign in.")
            } else {
                ActionButton(title: isBusy ? "Preparing reset…" : "Continue to new password", icon: "arrow.right") { Task { await startPasswordResetAgain() } }.disabled(isBusy)
            }
            ActionButton(title: "Back to sign in", icon: "arrow.left") { openRoute("/login", label: "Sign in") }
        }
    }

    private var pendingDeletionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if restored || model.hasHanasandAuth {
                Text("Account restored. You are signed in as @\(model.userIDForRequests).")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Continue to dashboard", icon: "arrow.right") { continueAfterAuthentication() }
            } else {
                Text("\(query["id"].map { "@\($0) is " } ?? "This account is ")scheduled to be deleted \(query["deletionScheduledAt"] ?? "at the scheduled time").")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if model.pendingDeletionUserID.isEmpty || model.pendingDeletionRestoreToken.isEmpty {
                    NativeEmptyState(title: "Restore link is incomplete", message: "Return to sign in and request a fresh recovery link.")
                } else {
                    ActionButton(title: model.isRestoringPendingDeletion ? "Restoring…" : "Restore account", icon: "arrow.uturn.backward") { Task { await restoreAccount() } }.disabled(model.isRestoringPendingDeletion)
                }
                ActionButton(title: "Go back to sign in", icon: "arrow.left") { openRoute("/login", label: "Sign in") }
            }
        }
    }

    private var continueButton: some View {
        ActionButton(title: "Continue", icon: "arrow.right") { continueAfterAuthentication() }
    }

    private var filteredReturnQuery: [String: String] {
        guard let path = safeLocalPath(query["path"]) else { return [:] }
        return ["path": path]
    }

    private var canSubmitSignup: Bool {
        let name = signupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = ReservedUsernamePolicy.normalizedSignupUsername(signupUsername)
        let email = signupEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, username.range(of: "^[a-z0-9][a-z0-9._-]{2,39}$", options: .regularExpression) != nil,
              !ReservedUsernamePolicy.usernames.contains(username),
              email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil,
              AccountSignupClient.passwordMeetsRequirements(signupPassword) else { return false }
        return !signupWaitingForCode || (signupChallengeID != nil && signupCode.count == 6)
    }

    private var signupUsernameIsReserved: Bool {
        ReservedUsernamePolicy.usernames.contains(ReservedUsernamePolicy.normalizedSignupUsername(signupUsername))
    }

    @ViewBuilder private func signupActionButtons(vertical: Bool) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: 8) {
                signupActionButtonsContent
            }
        } else {
            HStack(spacing: 8) {
                signupActionButtonsContent
            }
        }
    }

    @ViewBuilder private var signupActionButtonsContent: some View {
        ActionButton(title: isBusy && !signupWaitingForCode ? "Sending…" : signupWaitingForCode ? "Verify and create account" : "Send verification code", icon: "envelope.badge") { Task { await submitSignup() } }
            .disabled(isBusy || !canSubmitSignup)
        if signupWaitingForCode {
            ActionButton(title: isBusy && isResendingSignupCode ? "Sending…" : "Send new code", icon: "envelope") { Task { await submitSignup(resendCode: true) } }
                .disabled(isBusy)
            ActionButton(title: "Start over", icon: "arrow.counterclockwise") {
                signupWaitingForCode = false; signupChallengeID = nil; signupCode = ""; message = ""
            }.disabled(isBusy)
        }
    }

    @MainActor private func prepareRoute() async {
        guard preparedTaskIdentity != taskIdentity else { return }
        preparedTaskIdentity = taskIdentity
        routePrepared = false
        switch kind {
        case .login:
            if let username = query["username"], !username.isEmpty { model.loginUsername = username }
            if let error = query["error"], !error.isEmpty {
                let cleanError = String(String.UnicodeScalarView(error.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                message = String(cleanError.prefix(500))
            }
            else if query["expired"] == "true" || query["expired"] == "1" { message = "Your previous sign-in expired. Sign in again to continue." }
        case .signup:
            if let returnPath = safeLocalPath(query["path"]) { message = "After sign in, you can continue to \(returnPath)." }
            if let error = query["error"], !error.isEmpty { message = String(error.prefix(500)) }
        case .logout:
            if model.hasHanasandAuth { await signOut() }
            else { message = "This Desktop session is signed out." }
        case .secureAccount, .resetPasswordAgain:
            actionToken = safeRouteSecret(query["token"]) ?? ""
            removeSensitiveRouteValues(["token"])
        case .resetPassword:
            resetUserID = safeAccountID(query["id"]) ?? ""
            let token = safeRouteSecret(query["token"]) ?? ""
            removeSensitiveRouteValues(["token"])
            if !resetUserID.isEmpty, !token.isEmpty {
                model.passwordResetUsername = resetUserID
                model.passwordResetToken = token
                model.passwordResetNewPassword = ""
                model.passwordResetConfirmPassword = ""
                model.passwordResetStatus = ""
                model.passwordResetStep = .newPassword
            } else if resetUserID.isEmpty || model.passwordResetStep != .newPassword || model.passwordResetUsername != resetUserID {
                model.cancelPasswordReset()
            }
        case .pendingDeletion:
            model.pendingDeletionUserID = safeAccountID(query["id"]) ?? ""
            model.pendingDeletionRestoreToken = safeRouteSecret(query["restoreToken"]) ?? ""
            model.pendingDeletionScheduledAt = String((query["deletionScheduledAt"] ?? "").prefix(100))
            model.pendingDeletionStatus = ""
            removeSensitiveRouteValues(["restoreToken"])
        case .switchAccount:
            await loadProfiles()
        case .loadTest:
            break
        case .upload:
            break
        case nil:
            break
        }
        routePrepared = true
    }

    @MainActor private func signIn() async {
        await model.loginToHanasand()
        if model.hasHanasandAuth {
            try? saveCurrentProfile()
            message = "Signed in as @\(model.userIDForRequests)."
        }
    }

    @MainActor private func submitSignup(resendCode: Bool = false) async {
        guard !isBusy, (resendCode ? signupWaitingForCode : canSubmitSignup) else { return }
        isBusy = true
        isResendingSignupCode = resendCode
        defer { isBusy = false }
        defer { isResendingSignupCode = false }
        do {
            let result = try await model.submitAccountSignup(
                name: signupName, username: signupUsername, email: signupEmail, password: signupPassword,
                challengeID: resendCode ? nil : signupChallengeID, code: resendCode || !signupWaitingForCode ? nil : signupCode)
            if case let .verificationRequired(challengeID) = result {
                signupChallengeID = challengeID
                signupWaitingForCode = true
                signupCode = ""
                message = resendCode
                    ? "New verification code sent. Check your email and use the latest code."
                    : "Verification code sent. Check your email and enter the six-digit code."
            } else if model.hasHanasandAuth {
                try? saveCurrentProfile()
                message = "Account created and signed in as @\(model.userIDForRequests)."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor private func signOut() async {
        isBusy = true
        defer { isBusy = false }
        await model.logoutFromHanasand()
        message = model.hasHanasandAuth ? "Unable to clear the signed-in session." : "Signed out. Continue to sign in again."
        routePrepared = true
    }

    @MainActor private func lockAccount() async {
        await postTokenAction("auth/password-reset/lock-account") { _ in
            locked = true
            if model.hasHanasandAuth { await model.logoutFromHanasand(revokeRemoteSession: false) }
            message = "Your account is locked. Reset the password before signing in again."
        }
    }

    @MainActor private func startPasswordResetAgain() async {
        guard !isBusy, !actionToken.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let response: NativePasswordResetAgainResponse = try await postTokenJSON("auth/password-reset/start-again")
            guard !response.id.isEmpty, !response.resetToken.isEmpty else {
                message = response.error ?? "The reset service returned an incomplete response."
                return
            }
            resetUserID = response.id
            model.passwordResetUsername = response.id
            model.passwordResetToken = response.resetToken
            model.passwordResetNewPassword = ""
            model.passwordResetConfirmPassword = ""
            model.passwordResetStatus = ""
            model.passwordResetStep = .newPassword
            model.openNativeDashboard(path: "/reset-password", label: "Set new password", query: ["id": response.id])
            actionToken = ""
            message = "Reset session ready. Choose your new password."
        } catch { message = error.localizedDescription }
    }

    @MainActor private func completePasswordReset() async {
        await model.completePasswordReset()
        if model.passwordResetStatus.isEmpty, model.passwordResetStep == .idle, !model.loginStatus.isEmpty {
            message = model.loginStatus
            resetCompleted = true
        }
    }

    @MainActor private func restoreAccount() async {
        await model.restorePendingDeletionAccount()
        if model.hasHanasandAuth {
            restored = true
            message = "Account restored and signed in."
        } else {
            message = model.pendingDeletionStatus
        }
    }

    @MainActor private func loadProfiles() async {
        do {
            if model.hasHanasandAuth { try saveCurrentProfile() }
            savedProfiles = try NativeSavedAccountProfiles.read()
            profilesError = ""
        } catch { profilesError = "Could not read saved profiles from Keychain: \(error.localizedDescription)" }
    }

    @MainActor private func saveCurrentProfile() throws {
        guard model.hasHanasandAuth,
              model.settings.impersonationToken.isEmpty,
              model.settings.impersonatingUserID.isEmpty else { return }
        try NativeSavedAccountProfiles.save(.init(id: model.userIDForRequests, token: model.authTokenForRequests, lastUsedAt: Date()))
        savedProfiles = try NativeSavedAccountProfiles.read()
    }

    @MainActor private func switchTo(_ profile: NativeSavedAccountProfile) async {
        guard profile.id != model.userIDForRequests, !profile.token.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try saveCurrentProfile()
            try DesktopCredentialStore.write(profile.token, for: .authToken)
            try DesktopCredentialStore.write("", for: .impersonationToken)
            model.settings.authToken = profile.token
            model.settings.userID = profile.id
            model.settings.impersonationToken = ""
            model.settings.impersonatingUserID = ""
            model.settings.impersonatingUserName = ""
            model.settings.selectedOrganizationID = ""
            model.settings.selectedOrganizationUserID = ""
            model.loginUsername = ""
            model.loginPassword = ""
            model.selectedSection = .dashboard
            model.beginDesktopAgentPresence()
            message = "Switched to @\(profile.id)."
            model.openNativeDashboard(path: "/dashboard", label: "Dashboard")
        } catch { profilesError = "Could not switch profiles: \(error.localizedDescription)" }
    }

    @MainActor private func beginAddingProfile() async {
        do { try saveCurrentProfile() }
        catch { profilesError = "Could not save the current profile in Keychain: \(error.localizedDescription)"; return }
        addingProfile = true
        await model.logoutFromHanasand(revokeRemoteSession: false)
        model.loginUsername = ""
        model.loginPassword = ""
        message = "Sign in to add another profile. The existing profile stays saved in Keychain."
    }

    @MainActor private func forgetProfiles() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let profiles = try NativeSavedAccountProfiles.read()
            let url = model.settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/sessions/revoke")
            guard url.usesSecureHanasandTransport else { throw NativeAccountRouteError.insecureEndpoint }
            for profile in profiles {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
                request.setValue(profile.id, forHTTPHeaderField: "id")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("{\"keep_current\":false}".utf8)
                _ = try? await NativeAccountRouteSession.shared.data(for: request)
            }
            try NativeSavedAccountProfiles.removeAll()
            savedProfiles = []
            await model.logoutFromHanasand(revokeRemoteSession: false)
            message = "Saved profiles removed and signed out on this Desktop."
        } catch { profilesError = "Could not remove saved profiles: \(error.localizedDescription)" }
    }

    @MainActor private func postTokenAction(_ endpoint: String, success: @escaping (NativeTokenActionResponse) async -> Void) async {
        guard !actionToken.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let response: NativeTokenActionResponse = try await postTokenJSON(endpoint)
            if let error = response.error, !error.isEmpty { message = error; return }
            actionToken = ""
            await success(response)
        } catch { message = error.localizedDescription }
    }

    private func postTokenJSON<T: Decodable>(_ endpoint: String) async throws -> T {
        let url = model.settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(endpoint)
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw NativeAccountRouteError.insecureEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(["token": actionToken])
        let (data, response) = try await NativeAccountRouteSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = (try? JSONDecoder().decode(NativeTokenActionResponse.self, from: data))?.error
            throw NativeAccountRouteError.request(error ?? "Account action failed (HTTP \(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @MainActor private func openRoute(_ path: String, label: String, query extra: [String: String] = [:]) {
        if path != "/reset-password", model.passwordResetStep != .idle { model.cancelPasswordReset() }
        model.openNativeDashboard(path: path, label: label, query: extra)
    }

    @MainActor private func continueAfterAuthentication() {
        guard let rawPath = safeLocalPath(query["path"]),
              let url = URL(string: rawPath, relativeTo: model.settings.websiteBaseURL.normalizedBaseURL)?.absoluteURL,
              let route = BrowserWorkspaceModel.nativeRoute(for: url.absoluteString, configuredWebsiteBaseURL: model.settings.websiteBaseURL) else {
            model.openNativeDashboard(path: "/dashboard", label: "Dashboard")
            return
        }
        _ = model.openNativeHanasandRoute(route)
    }

    @MainActor private func removeSensitiveRouteValues(_ keys: Set<String>) {
        for key in keys { model.selectedNativeDashboardQuery.removeValue(forKey: key) }
    }

    private func safeLocalPath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), !value.hasPrefix("//"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: value), components.scheme == nil, components.host == nil else { return nil }
        return value
    }

    private func safeAccountID(_ value: String?) -> String? {
        guard let value, value.range(of: "^[A-Za-z0-9._-]{1,254}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private func safeRouteSecret(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 8_192,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}

private enum NativeAccountRouteError: LocalizedError {
    case insecureEndpoint
    case request(String)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint: "Account action requires a secure Hanasand API address."
        case .request(let message): message
        }
    }
}
