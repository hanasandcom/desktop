import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct AccountSignupResponse: Decodable {
    let id: String?
    let token: String?
    let expiresAt: String?
    let error: String?
    let verificationRequired: Bool?
    let challengeId: String?

    enum CodingKeys: String, CodingKey {
        case id, token, error
        case expiresAt = "expires_at"
        case verificationRequired, challengeId
    }
}

enum AccountSignupResult {
    case verificationRequired(challengeID: String)
    case authenticated(HanasandLoginResponse)
}

enum AccountSignupError: LocalizedError {
    case invalidBaseURL
    case invalidName
    case invalidUsername
    case invalidEmail
    case weakPassword
    case invalidVerification
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Account creation requires a valid secure API address."
        case .invalidName: "Enter your name (up to 100 characters)."
        case .invalidUsername: "Use 3–40 letters, numbers, dots, underscores or hyphens for your username."
        case .invalidEmail: "Enter a valid email address."
        case .weakPassword: "Use at least 16 characters, including one uppercase letter, one lowercase letter, one number, and one special character."
        case .invalidVerification: "Enter the six-digit code sent to your email."
        case .invalidResponse: "The account service returned an invalid response. Try again."
        case let .requestFailed(message): message
        }
    }
}

private final class AccountSignupRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum AccountSignupSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: AccountSignupRedirectDelegate(), delegateQueue: nil)
    }()
}

struct AccountSignupClient {
    let endpoint: URL
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await AccountSignupSession.shared.data(for: request)
    }

    init(baseURL: URL, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw AccountSignupError.invalidBaseURL
        }
        let normalized = baseURL.appendingAPIPath("user")
        guard normalized.scheme?.lowercased() == "https", normalized.host == baseURL.host else {
            throw AccountSignupError.invalidBaseURL
        }
        endpoint = normalized
        if let send { self.send = send }
    }

    func submit(name: String, username: String, email: String, password: String, challengeID: String? = nil, code: String? = nil) async throws -> AccountSignupResult {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanName.isEmpty, cleanName.count <= 100 else { throw AccountSignupError.invalidName }
        guard cleanUsername.range(of: "^[a-z0-9][a-z0-9._-]{2,39}$", options: .regularExpression) != nil else {
            throw AccountSignupError.invalidUsername
        }
        guard cleanEmail.count <= 254, cleanEmail.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil else {
            throw AccountSignupError.invalidEmail
        }
        guard Self.passwordMeetsRequirements(password) else { throw AccountSignupError.weakPassword }
        if challengeID != nil || code != nil {
            guard let challengeID, challengeID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: [.regularExpression, .caseInsensitive]) != nil,
                  let code, code.range(of: "^\\d{6}$", options: .regularExpression) != nil else {
                throw AccountSignupError.invalidVerification
            }
        }

        var payload: [String: String] = ["id": cleanUsername, "name": cleanName, "email": cleanEmail, "password": password]
        if let challengeID, let code { payload["challengeId"] = challengeID; payload["code"] = code }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw AccountSignupError.invalidResponse }
        let result = try? JSONDecoder().decode(AccountSignupResponse.self, from: data)
        if http.statusCode == 202, result?.verificationRequired == true,
           let challengeID = result?.challengeId, UUID(uuidString: challengeID) != nil {
            return .verificationRequired(challengeID: challengeID)
        }
        if (200..<300).contains(http.statusCode), let result, let token = result.token, !token.isEmpty {
            return .authenticated(HanasandLoginResponse(id: result.id, token: token, expiresAt: result.expiresAt, error: nil, pendingDeletion: nil, deletionScheduledAt: nil, restoreToken: nil))
        }
        let message = result?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw AccountSignupError.requestFailed(message?.isEmpty == false ? message! : "Account creation failed (HTTP \(http.statusCode)).")
    }

    static func passwordMeetsRequirements(_ password: String) -> Bool {
        password.count >= 16
            && password.range(of: "[A-Z]", options: .regularExpression) != nil
            && password.range(of: "[a-z]", options: .regularExpression) != nil
            && password.range(of: "[0-9]", options: .regularExpression) != nil
            && password.range(of: "[^a-zA-Z0-9\\s]", options: .regularExpression) != nil
    }
}

extension DesktopAgentModel {

    func submitAccountSignup(name: String, username: String, email: String, password: String, challengeID: String? = nil, code: String? = nil) async throws -> AccountSignupResult {
        guard !isLoggingIn else { throw AccountSignupError.requestFailed("Account creation is already in progress.") }
        isLoggingIn = true
        loginStatus = challengeID == nil ? "Creating account" : "Verifying email"
        defer { isLoggingIn = false }
        do {
            let client = try AccountSignupClient(baseURL: settings.apiBaseURL.normalizedBaseURL)
            let result = try await client.submit(name: name, username: username, email: email, password: password, challengeID: challengeID, code: code)
            switch result {
            case .verificationRequired:
                loginStatus = "Verification code sent. Check your email and enter the six-digit code."
            case let .authenticated(response):
                try activateHanasandSession(response, fallbackUserID: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                loginStatus = ""
            }
            return result
        } catch {
            loginStatus = error.localizedDescription
            throw error
        }
    }

    func loginToHanasand() async {
        let username = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = loginPassword
        guard !username.isEmpty, !password.isEmpty, !isLoggingIn else {
            loginStatus = "Enter username and password."
            return
        }

        isLoggingIn = true
        loginStatus = "Signing in"
        defer { isLoggingIn = false }

        do {
            let url = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/login/\(username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username)")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Hanasand Desktop/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(HanasandLoginRequest(password: password))

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            let decoded = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data)

            if statusCode == 423, decoded?.pendingDeletion == true {
                pendingDeletionUserID = decoded?.id ?? username
                pendingDeletionRestoreToken = decoded?.restoreToken ?? ""
                pendingDeletionScheduledAt = decoded?.deletionScheduledAt ?? ""
                pendingDeletionStatus = ""
                loginPassword = ""
                loginStatus = ""
                return
            }

            guard (200..<300).contains(statusCode),
                  let decoded,
                  let token = decoded.token,
                  !token.isEmpty else {
                let message = decoded?.error
                    ?? String(data: data, encoding: .utf8)
                    ?? "Login failed."
                loginStatus = message
                return
            }

            try activateHanasandSession(decoded, fallbackUserID: username)
        } catch {
            loginStatus = error.localizedDescription
        }
    }

    func restorePendingDeletionAccount() async {
        let userID = pendingDeletionUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let restoreToken = pendingDeletionRestoreToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !restoreToken.isEmpty, !isRestoringPendingDeletion else {
            pendingDeletionStatus = "Restore details are missing."
            return
        }

        isRestoringPendingDeletion = true
        pendingDeletionStatus = "Restoring"
        defer { isRestoringPendingDeletion = false }

        do {
            let body = try JSONEncoder().encode(["id": userID, "restoreToken": restoreToken])
            let url = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user/restore")
            let (data, response) = try await URLSession.shared.data(for: request(url, method: "POST", body: body, authenticated: false))
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            let decoded = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data)
            guard (200..<300).contains(statusCode), let token = decoded?.token, !token.isEmpty else {
                pendingDeletionStatus = decoded?.error ?? String(data: data, encoding: .utf8) ?? "Unable to restore account."
                return
            }

            clearPendingDeletionState()
            try DesktopCredentialStore.write(token, for: .authToken)
            try DesktopCredentialStore.write("", for: .impersonationToken)
            settings.authToken = token
            settings.userID = decoded?.id ?? userID
            settings.impersonationToken = ""
            settings.impersonatingUserID = ""
            settings.impersonatingUserName = ""
            loginUsername = ""
            loginPassword = ""
            loginStatus = ""
            append(meta: "Account restored", body: "Signed in as \(settings.userID).", kind: .change)
            beginDesktopAgentPresence()
        } catch {
            pendingDeletionStatus = error.localizedDescription
        }
    }

    func clearPendingDeletionState() {
        pendingDeletionUserID = ""
        pendingDeletionRestoreToken = ""
        pendingDeletionScheduledAt = ""
        pendingDeletionStatus = ""
    }

    func logoutFromHanasand(revokeRemoteSession: Bool = true) async {
        let currentUserID = userIDForRequests.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadAuth = hasHanasandAuth

        if revokeRemoteSession, hadAuth {
            do {
                let body = (try? JSONEncoder().encode(["keep_current": false])) ?? Data("{}".utf8)
                _ = try await requestPrettyText(
                    settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/sessions/revoke"),
                    method: "POST",
                    body: body,
                    authenticated: true
                )
            } catch {
                append(meta: "Logout revoke failed", body: error.localizedDescription, kind: .error)
            }
        }

        do {
            try DesktopCredentialStore.write("", for: .authToken)
            try DesktopCredentialStore.write("", for: .impersonationToken)
        } catch {
            loginStatus = "Unable to securely clear the Hanasand session. Try logging out again."
            append(meta: "Logout cleanup failed", body: error.localizedDescription, kind: .error)
            return
        }

        clearLocalHanasandSession()
        let label = currentUserID.isEmpty ? "current account" : currentUserID
        append(meta: "Logout", body: "Signed out \(label).", kind: .change)
    }

    func clearLocalHanasandSession() {
        desktopPresenceTask?.cancel()
        desktopPresenceTask = nil
        settings.authToken = ""
        settings.userID = ""
        settings.impersonationToken = ""
        settings.impersonatingUserID = ""
        settings.impersonatingUserName = ""
        loginUsername = ""
        loginPassword = ""
        loginStatus = ""
        clearPendingDeletionState()
        cancelPasswordReset()
        selectedSection = .control
        disconnectAISocket()
        aiSummary = "Ready to connect"
        aiClients = []
        aiSocketConnected = false
        mailOverview = nil
        mailSummary = "Ready to load inbox"
        selectedMailAccountUser = ""
        selectedMailMessageID = ""
        selectedMailboxID = ""
        profile = nil
        profileSessions = []
        profileCertificates = []
        profileSshKeys = []
        profileSshKeyError = nil
        profileSshKeyNotice = nil
        profileSshKeyLoadError = nil
        nativeDashboardStatus = "Logged out"
    }

    func scheduleAccountDeletion() async {
        guard hasHanasandAuth else {
            nativeDashboardStatus = "Hanasand session is not ready. Log in again if this persists."
            return
        }

        do {
            _ = try await requestPrettyText(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("user/self"),
                method: "DELETE",
                authenticated: true
            )
            await logoutFromHanasand(revokeRemoteSession: false)
        } catch {
            nativeDashboardStatus = error.localizedDescription
            append(meta: "Account deletion failed", body: error.localizedDescription, kind: .error)
        }
    }

    func beginPasswordReset() {
        let username = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        passwordResetUsername = username
        passwordResetCode = ""
        passwordResetToken = ""
        passwordResetNewPassword = ""
        passwordResetConfirmPassword = ""
        passwordResetStatus = ""
        lastAutoVerifiedPasswordResetCode = ""
        passwordResetStep = .code
    }

    func cancelPasswordReset() {
        passwordResetCode = ""
        passwordResetToken = ""
        passwordResetNewPassword = ""
        passwordResetConfirmPassword = ""
        passwordResetStatus = ""
        lastAutoVerifiedPasswordResetCode = ""
        passwordResetStep = .idle
    }

    func updatePasswordResetCode(_ rawValue: String) {
        let clean = String(rawValue.filter(\.isNumber).prefix(6))
        if passwordResetCode != clean {
            passwordResetCode = clean
        }
        if clean.count < 6 {
            lastAutoVerifiedPasswordResetCode = ""
            return
        }
        autoVerifyPasswordResetCodeIfReady()
    }

    func autoVerifyPasswordResetCodeIfReady() {
        let username = passwordResetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = passwordResetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard passwordResetStep == .code, !username.isEmpty, code.count == 6, !isResettingPassword else { return }
        guard lastAutoVerifiedPasswordResetCode != code else { return }
        lastAutoVerifiedPasswordResetCode = code
        Task { await verifyPasswordResetCode() }
    }

    func requestPasswordResetCode() async {
        let username = passwordResetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !isResettingPassword else {
            passwordResetStatus = "Type your username first."
            return
        }

        isResettingPassword = true
        passwordResetStatus = "Sending code"
        defer { isResettingPassword = false }

        do {
            let url = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/password-reset/request")
            let body = try JSONEncoder().encode(PasswordResetRequestPayload(id: username))
            let response: PasswordResetResponse = try await passwordResetJSON(url, body: body)
            if let error = response.error, !error.isEmpty {
                passwordResetStatus = error
                return
            }

            passwordResetUsername = username
            passwordResetCode = ""
            passwordResetToken = ""
            lastAutoVerifiedPasswordResetCode = ""
            passwordResetStep = .code
            passwordResetStatus = "Check your mail for the 6 digit code."
        } catch {
            passwordResetStatus = error.localizedDescription
        }
    }

    func verifyPasswordResetCode() async {
        let username = passwordResetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = passwordResetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, code.count == 6, !isResettingPassword else {
            passwordResetStatus = "Enter the 6 digit code."
            return
        }

        isResettingPassword = true
        passwordResetStatus = "Checking code"
        defer { isResettingPassword = false }

        do {
            let url = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/password-reset/verify")
            let body = try JSONEncoder().encode(PasswordResetVerifyPayload(id: username, code: code))
            let response: PasswordResetVerifyResponse = try await passwordResetJSON(url, body: body)
            guard let token = response.resetToken, !token.isEmpty else {
                lastAutoVerifiedPasswordResetCode = ""
                passwordResetStatus = response.error ?? "Invalid reset code."
                return
            }

            passwordResetToken = token
            passwordResetNewPassword = ""
            passwordResetConfirmPassword = ""
            passwordResetStep = .newPassword
            passwordResetStatus = "Code accepted."
        } catch {
            lastAutoVerifiedPasswordResetCode = ""
            passwordResetStatus = error.localizedDescription
        }
    }
}
