import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import SwiftUI

private let passkeySignInEnabled = false

private struct PasskeyAuthenticationOptions: Decodable {
    let challengeId: String
    let publicKey: PublicKey

    struct PublicKey: Decodable {
        let challenge: String
        let rpId: String
        let allowCredentials: [CredentialDescriptor]?
    }

    struct CredentialDescriptor: Decodable {
        let id: String
    }
}

private struct MobileSsoCodeResponse: Decodable {
    let id: String?
    let token: String?
    let error: String?
}

private struct MobilePasskeyPayload: Encodable {
    let challengeId: String
    let credential: Credential

    struct Credential: Encodable {
        let id: String
        let rawId: String
        let type = "public-key"
        let response: Assertion
    }

    struct Assertion: Encodable {
        let authenticatorData: String
        let clientDataJSON: String
        let signature: String
        let userHandle: String
    }
}

extension DesktopAgentModel {
    func loginWithPasskey() async {
        guard passkeySignInEnabled else {
            loginStatus = "Passkey sign-in is temporarily unavailable."
            return
        }
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginStatus = "Waiting for passkey"
        defer { isLoggingIn = false }

        do {
            var optionsURL = try authenticationURL("auth/passkeys/authenticate/options")
            let username = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                var components = URLComponents(url: optionsURL, resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "username", value: username)]
                guard let url = components?.url else { throw ModernAuthenticationError.invalidResponse }
                optionsURL = url
            }

            var optionsRequest = URLRequest(url: optionsURL)
            optionsRequest.timeoutInterval = 15
            optionsRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            optionsRequest.setValue("Hanasand Desktop/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (optionsData, optionsResponse) = try await AccountCredentialTransport.shared.data(for: optionsRequest)
            guard (optionsResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw authenticationError(from: optionsData, fallback: "Passkey sign-in is unavailable.")
            }

            let options = try JSONDecoder().decode(PasskeyAuthenticationOptions.self, from: optionsData)
            guard let challenge = Data(base64URLString: options.publicKey.challenge),
                  !options.challengeId.isEmpty,
                  !options.publicKey.rpId.isEmpty else {
                throw ModernAuthenticationError.invalidResponse
            }

            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.publicKey.rpId)
            let assertionRequest = provider.createCredentialAssertionRequest(challenge: challenge)
            assertionRequest.allowedCredentials = try (options.publicKey.allowCredentials ?? []).map { descriptor in
                guard let credentialID = Data(base64URLString: descriptor.id) else {
                    throw ModernAuthenticationError.invalidResponse
                }
                return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialID)
            }

            let assertion = try await PasskeyAuthorizationCoordinator.shared.authorize(assertionRequest)
            let rawID = assertion.credentialID.base64URLString
            let payload = MobilePasskeyPayload(
                challengeId: options.challengeId,
                credential: .init(
                    id: rawID,
                    rawId: rawID,
                    response: .init(
                        authenticatorData: assertion.rawAuthenticatorData.base64URLString,
                        clientDataJSON: assertion.rawClientDataJSON.base64URLString,
                        signature: assertion.signature.base64URLString,
                        userHandle: assertion.userID.base64URLString
                    )
                )
            )
            let verifyData = try JSONEncoder().encode(payload)
            let (data, response) = try await AccountCredentialTransport.shared.data(for: jsonRequest(
                url: authenticationURL("auth/mobile/passkeys/authenticate/verify"),
                body: verifyData
            ))
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode),
                  let decoded = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data),
                  let token = decoded.token, !token.isEmpty else {
                throw authenticationError(from: data, fallback: "Passkey sign-in could not be completed.")
            }
            try activateHanasandSession(decoded, fallbackUserID: username)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            loginStatus = "Passkey sign-in was canceled."
        } catch {
            loginStatus = error.localizedDescription
        }
    }

    func beginHanasandSso() {
        guard !isLoggingIn else { return }
        do {
            let verifier = try makeCodeVerifier()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
            var components = URLComponents(url: try authenticationURL("auth/mobile/sso/start"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "client", value: "desktop"),
            ]
            guard let url = components?.url else { throw ModernAuthenticationError.invalidResponse }
            loginStatus = "Opening secure sign-in"
            isLoggingIn = true
            try DesktopSsoSession.shared.start(url: url, verifier: verifier, model: self)
        } catch {
            isLoggingIn = false
            loginStatus = error.localizedDescription
        }
    }

    func beginGoogleSignIn() async {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginStatus = "Checking Google sign-in"
        do {
            let client = DesktopGoogleOAuthClient(websiteBaseURL: settings.websiteBaseURL.normalizedBaseURL)
            guard try await client.isConfigured() else {
                throw DesktopGoogleOAuthError.server("Google sign-in is not configured on the server yet.")
            }
            let verifier = try makeCodeVerifier()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
            let url = try client.authorizationURL(challenge: challenge)
            loginStatus = "Connecting to Google"
            try DesktopGoogleSignInSession.shared.start(url: url, verifier: verifier, model: self)
        } catch {
            isLoggingIn = false
            loginStatus = error.localizedDescription
        }
    }

    func completeHanasandGoogleSignIn(code: String, verifier: String) async {
        defer { isLoggingIn = false }
        loginStatus = "Completing Google sign-in"
        do {
            let client = DesktopGoogleOAuthClient(websiteBaseURL: settings.websiteBaseURL.normalizedBaseURL)
            let response = try await client.exchange(code: code, verifier: verifier)
            try activateHanasandSession(response, fallbackUserID: "")
        } catch {
            loginStatus = error.localizedDescription
        }
    }

    func completeGoogleSignInWithError(_ message: String) {
        isLoggingIn = false
        loginStatus = message
    }

    func completeHanasandSso(code: String, verifier: String) async {
        defer { isLoggingIn = false }
        loginStatus = "Completing sign-in"
        guard code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              verifier.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else {
            loginStatus = "SSO sign-in could not be completed."
            return
        }

        do {
            let body = try JSONEncoder().encode(["code": code, "verifier": verifier])
            let request = jsonRequest(
                url: try authenticationURL("auth/mobile/sso/exchange"),
                body: body
            )
            let outgoing = try DesktopDeviceProof.attachingPublicJWK(
                request,
                configuredOrigins: [settings.websiteBaseURL.normalizedBaseURL, settings.apiBaseURL.normalizedBaseURL]
            )
            let (data, response) = try await AccountCredentialTransport.shared.data(for: outgoing)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode),
                  let decoded = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data),
                  let token = decoded.token, !token.isEmpty else {
                throw authenticationError(from: data, fallback: "SSO sign-in could not be completed.")
            }
            try activateHanasandSession(decoded, fallbackUserID: "")
        } catch {
            loginStatus = error.localizedDescription
        }
    }

    func completeHanasandSsoWithError(_ message: String) {
        isLoggingIn = false
        loginStatus = message
    }

    func activateHanasandSession(_ response: HanasandLoginResponse, fallbackUserID: String) throws {
        guard let token = response.token, !token.isEmpty else {
            throw ModernAuthenticationError.invalidResponse
        }
        try DesktopCredentialStore.write(token, for: .authToken)
        try DesktopCredentialStore.write("", for: .impersonationToken)
        settings.authToken = token
        settings.userID = response.id ?? fallbackUserID
        settings.impersonationToken = ""
        settings.impersonatingUserID = ""
        settings.impersonatingUserName = ""
        loginUsername = ""
        loginPassword = ""
        loginStatus = ""
        append(meta: "Login", body: "Signed in as \(settings.userID).", kind: .change)
        beginDesktopAgentPresence()
    }

    private func authenticationURL(_ path: String) throws -> URL {
        let url = settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath("api/\(path)")
        guard url.usesSecureHanasandTransport else { throw ModernAuthenticationError.insecureEndpoint }
        return url
    }

    private func jsonRequest(url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Hanasand Desktop/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    private func authenticationError(from data: Data, fallback: String) -> Error {
        let response = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data)
        return ModernAuthenticationError.server(response?.error ?? fallback)
    }
}

@MainActor
private final class PasskeyAuthorizationCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = PasskeyAuthorizationCoordinator()

    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>?

    func authorize(_ request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            finish(.failure(ModernAuthenticationError.invalidResponse))
            return
        }
        finish(.success(assertion))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }

    private func finish(_ result: Result<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>) {
        controller = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class DesktopSsoSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DesktopSsoSession()

    private var session: ASWebAuthenticationSession?
    private weak var model: DesktopAgentModel?
    private var verifier = ""

    func start(url: URL, verifier: String, model: DesktopAgentModel) throws {
        self.model = model
        self.verifier = verifier
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "hanasand-desktop") { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.finish(callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else {
            self.session = nil
            self.model = nil
            self.verifier = ""
            throw ModernAuthenticationError.ssoCouldNotStart
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }

    private func finish(callbackURL: URL?, error: Error?) {
        session = nil
        let verifier = self.verifier
        self.verifier = ""
        guard let model else { return }
        self.model = nil

        guard let callbackURL,
              let code = DesktopSsoCallback.authorizationCode(from: callbackURL) else {
            let message = error == nil ? "SSO sign-in could not be completed." : "SSO sign-in was canceled or failed."
            model.completeHanasandSsoWithError(message)
            return
        }

        Task { await model.completeHanasandSso(code: code, verifier: verifier) }
    }
}

@MainActor
private final class DesktopGoogleSignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DesktopGoogleSignInSession()

    private var session: ASWebAuthenticationSession?
    private weak var model: DesktopAgentModel?
    private var verifier = ""

    func start(url: URL, verifier: String, model: DesktopAgentModel) throws {
        self.model = model
        self.verifier = verifier
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "hanasand") { [weak self] callbackURL, error in
            Task { @MainActor in self?.finish(callbackURL: callbackURL, error: error) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else {
            self.session = nil
            self.model = nil
            self.verifier = ""
            throw DesktopGoogleOAuthError.couldNotStart
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }

    private func finish(callbackURL: URL?, error: Error?) {
        session = nil
        let verifier = self.verifier
        self.verifier = ""
        guard let model else { return }
        self.model = nil
        let wasCancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
        let result = DesktopGoogleOAuthCallback.sessionOutcome(callbackURL: callbackURL, wasCancelled: wasCancelled)
        switch result {
        case .success(let code):
            Task { await model.completeHanasandGoogleSignIn(code: code, verifier: verifier) }
        case .failure(let failure):
            let message = failure == .invalidResponse && callbackURL != nil
                ? "Google sign-in returned an invalid callback."
                : failure.localizedDescription
            model.completeGoogleSignInWithError(message)
        }
    }
}

enum DesktopSsoCallback {
    static func authorizationCode(from callbackURL: URL) -> String? {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "hanasand-desktop",
              components.host?.lowercased() == "sso",
              components.path.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "code",
              let code = queryItems[0].value,
              code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            return nil
        }
        return code
    }
}

private enum ModernAuthenticationError: LocalizedError {
    case insecureEndpoint
    case invalidResponse
    case ssoCouldNotStart
    case server(String)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint:
            return "Sign-in requires a secure HTTPS website."
        case .invalidResponse:
            return "The sign-in service returned an invalid response."
        case .ssoCouldNotStart:
            return "The secure sign-in window could not be opened."
        case .server(let message):
            return message
        }
    }
}

private func makeCodeVerifier() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw ModernAuthenticationError.invalidResponse }
    return Data(bytes).base64URLString
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - value.count % 4) % 4
        value.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: value)
    }
}
