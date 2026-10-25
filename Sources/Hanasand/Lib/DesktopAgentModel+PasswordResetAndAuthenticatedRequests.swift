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

enum DesktopAuthenticatedRequestProof {
    static func enrichIfAuthenticated(
        _ request: URLRequest,
        authenticated: Bool,
        sessionToken: String,
        configuredAPIBaseURL: String,
        signer: (any DesktopDeviceProofSigning)? = nil
    ) throws -> URLRequest {
        guard authenticated else { return request }
        guard let requestURL = request.url,
              requestURL.scheme?.lowercased() == "https",
              let requestHost = requestURL.host?.lowercased() else {
            throw DesktopDeviceProofError.untrustedTarget
        }
        let configuredHost: Set<String>
        if let configured = URL(string: configuredAPIBaseURL),
           configured.scheme?.lowercased() == "https",
           let host = configured.host?.lowercased() {
            if !isHanasandHost(requestHost) {
                guard requestHost == host,
                      effectivePort(requestURL) == effectivePort(configured) else {
                    throw DesktopDeviceProofError.untrustedTarget
                }
            }
            configuredHost = [host]
        } else {
            guard isHanasandHost(requestHost) else { throw DesktopDeviceProofError.untrustedTarget }
            configuredHost = []
        }
        if let signer {
            return try DesktopDeviceProof.enrich(request, sessionToken: sessionToken,
                                                 customAllowedHosts: configuredHost, signer: signer)
        }
        return try DesktopDeviceProof.enrich(request, sessionToken: sessionToken,
                                             customAllowedHosts: configuredHost)
    }

    private static func isHanasandHost(_ host: String) -> Bool {
        host == "hanasand.com" || host.hasSuffix(".hanasand.com")
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }
}

extension DesktopAgentModel {

    func completePasswordReset() async {
        let username = passwordResetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !passwordResetToken.isEmpty, !isResettingPassword else {
            passwordResetStatus = "Reset session expired. Send a new code."
            return
        }
        guard passwordResetNewPassword == passwordResetConfirmPassword else {
            passwordResetStatus = "Passwords do not match."
            return
        }
        guard !passwordResetNewPassword.isEmpty else {
            passwordResetStatus = "Enter a new password."
            return
        }

        isResettingPassword = true
        passwordResetStatus = "Setting password"
        defer { isResettingPassword = false }

        do {
            let url = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("auth/password-reset/complete")
            let body = try JSONEncoder().encode(PasswordResetCompletePayload(
                id: username,
                resetToken: passwordResetToken,
                password: passwordResetNewPassword
            ))
            let response: PasswordResetResponse = try await passwordResetJSON(url, body: body)
            if let error = response.error, !error.isEmpty {
                passwordResetStatus = error
                return
            }

            loginUsername = username
            loginPassword = ""
            passwordResetCode = ""
            passwordResetToken = ""
            passwordResetNewPassword = ""
            passwordResetConfirmPassword = ""
            passwordResetStep = .idle
            loginStatus = "Password reset. Log in with the new one."
            passwordResetStatus = ""
        } catch {
            passwordResetStatus = error.localizedDescription
        }
    }

    func passwordResetJSON<T: Decodable>(_ url: URL, body: Data) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Hanasand Desktop/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, response) = try await AccountCredentialTransport.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (200..<300).contains(statusCode) {
            return try JSONDecoder().decode(T.self, from: data)
        }

        if let decoded = try? JSONDecoder().decode(PasswordResetResponse.self, from: data),
           let error = decoded.error,
           !error.isEmpty {
            throw PasswordResetRequestError.message(error)
        }

        throw PasswordResetRequestError.message("Password reset endpoint returned HTTP \(statusCode).")
    }

    var authTokenForRequests: String {
        let configured = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        let environment = ProcessInfo.processInfo.environment
        return environment["HANASAND_API_TOKEN"] ?? environment["HANASAND_AUTH_TOKEN"] ?? ""
    }

    var userIDForRequests: String {
        let configured = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return ProcessInfo.processInfo.environment["HANASAND_USER_ID"] ?? ""
    }

    var impersonatingUserIDForRequests: String {
        settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveUserIDForRequests: String {
        let target = impersonatingUserIDForRequests
        return target.isEmpty ? userIDForRequests : target
    }

    func saveSettings() {
        do {
            try DesktopCredentialStore.write(settings.authToken, for: .authToken)
            try DesktopCredentialStore.write(settings.impersonationToken, for: .impersonationToken)
        } catch {
            return
        }
        var persistedSettings = settings
        persistedSettings.authToken = ""
        persistedSettings.impersonationToken = ""
        guard let data = try? JSONEncoder().encode(persistedSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil, authenticated: Bool = false, userAgent: String? = nil) -> URLRequest {
        precondition(url.usesSecureHanasandTransport, "Blocked insecure plaintext endpoint: \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(userAgent ?? "Hanasand Desktop/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        if authenticated {
            request.setValue("Bearer \(authTokenForRequests)", forHTTPHeaderField: "Authorization")
            request.setValue(userIDForRequests, forHTTPHeaderField: "id")
            if !settings.impersonationToken.isEmpty {
                request.setValue(settings.impersonationToken, forHTTPHeaderField: "x-impersonation-token")
            }
        }
        return request
    }

    func mailOverviewURL() -> URL {
        var components = URLComponents(url: settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("mail/overview"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if !selectedMailAccountUser.isEmpty {
            items.append(URLQueryItem(name: "mailboxUser", value: selectedMailAccountUser))
        }
        if !selectedMailboxID.isEmpty {
            items.append(URLQueryItem(name: "mailboxId", value: selectedMailboxID))
        }
        if !selectedMailMessageID.isEmpty {
            items.append(URLQueryItem(name: "messageId", value: selectedMailMessageID))
        }
        if !items.isEmpty {
            components?.queryItems = items
        }
        return components?.url ?? settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("mail/overview")
    }

    func requestJSON<T: Decodable>(_ url: URL, method: String = "GET", body: Data? = nil, authenticated: Bool = false) async throws -> T {
        let outgoing = try outgoingRequest(url, method: method, body: body, authenticated: authenticated)
        let (data, response) = try await URLSession.shared.data(for: outgoing)
        try validateHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func accountCredentialJSON<T: Decodable>(_ url: URL, method: String = "GET", body: Data? = nil, authenticated: Bool = false) async throws -> T {
        let accountRequest = try outgoingRequest(url, method: method, body: body, authenticated: authenticated)
        let (data, response) = try await AccountCredentialTransport.shared.data(for: accountRequest)
        try validateHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func accountCredentialText(_ url: URL, method: String = "GET", body: Data? = nil, authenticated: Bool = false) async throws -> String {
        let accountRequest = try outgoingRequest(url, method: method, body: body, authenticated: authenticated)
        let (data, response) = try await AccountCredentialTransport.shared.data(for: accountRequest)
        try validateHTTP(response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func isValidShortcutDestination(_ path: String) -> Bool {
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.contains("http") || (clean.contains(".") && clean.count > 2) || clean.contains(":")
    }

    func requestText(_ url: URL, method: String = "GET", authenticated: Bool = false) async throws -> String {
        let outgoing = try outgoingRequest(url, method: method, authenticated: authenticated)
        let (data, response) = try await URLSession.shared.data(for: outgoing)
        try validateHTTP(response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func requestPrettyText(
        _ url: URL,
        method: String = "GET",
        body: Data? = nil,
        authenticated: Bool = false,
        userAgent: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> String {
        var outgoing = try outgoingRequest(url, method: method, body: body, authenticated: authenticated, userAgent: userAgent)
        if let idempotencyKey {
            guard (16...200).contains(idempotencyKey.utf8.count), !idempotencyKey.contains("\r"), !idempotencyKey.contains("\n") else {
                throw MailSendIdempotencyKeyError.invalid
            }
            outgoing.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await URLSession.shared.data(for: outgoing)
        try validateHTTP(response)
        if let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let pretty = String(data: prettyData, encoding: .utf8) {
            return pretty
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func outgoingRequest(_ url: URL, method: String = "GET", body: Data? = nil,
                                 authenticated: Bool, userAgent: String? = nil) throws -> URLRequest {
        let base = request(url, method: method, body: body, authenticated: authenticated, userAgent: userAgent)
        return try DesktopAuthenticatedRequestProof.enrichIfAuthenticated(
            base, authenticated: authenticated, sessionToken: authTokenForRequests,
            configuredAPIBaseURL: settings.apiBaseURL
        )
    }
}

enum MailSendIdempotencyKeyError: LocalizedError {
    case invalid

    var errorDescription: String? { "Unable to create a safe mail send request." }
}
