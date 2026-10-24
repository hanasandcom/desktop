import Foundation

struct DesktopGoogleOAuthClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let websiteBaseURL: URL
    private let transport: Transport

    init(websiteBaseURL: URL, transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.websiteBaseURL = websiteBaseURL
        self.transport = transport
    }

    func isConfigured() async throws -> Bool {
        let url = try endpoint("api/auth/social/providers")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = payload["providers"] as? [[String: Any]] else {
            throw DesktopGoogleOAuthError.invalidResponse
        }
        return providers.contains { $0["provider"] as? String == "google" && $0["configured"] as? Bool == true }
    }

    func authorizationURL(challenge: String) throws -> URL {
        guard challenge.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw DesktopGoogleOAuthError.invalidChallenge
        }
        var components = URLComponents(url: try endpoint("api/auth/social/google/start"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mobile_challenge", value: challenge)]
        guard let url = components?.url else { throw DesktopGoogleOAuthError.invalidResponse }
        return url
    }

    func exchange(code: String, verifier: String) async throws -> HanasandLoginResponse {
        guard code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              verifier.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else {
            throw DesktopGoogleOAuthError.invalidResponse
        }
        let body = try JSONEncoder().encode(ExchangePayload(code: code, verifier: verifier))
        var request = URLRequest(url: try endpoint("api/auth/mobile/sso/exchange"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let decoded = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data),
              let token = decoded.token, !token.isEmpty else {
            let decoded = try? JSONDecoder().decode(HanasandLoginResponse.self, from: data)
            throw DesktopGoogleOAuthError.server(decoded?.error ?? "Google sign-in could not be completed.")
        }
        return decoded
    }

    private func endpoint(_ path: String) throws -> URL {
        let url = websiteBaseURL.appendingAPIPath(path)
        guard url.usesSecureHanasandTransport, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw DesktopGoogleOAuthError.insecureEndpoint
        }
        return url
    }
}

enum DesktopGoogleOAuthCallback {
    static func sessionOutcome(callbackURL: URL?, wasCancelled: Bool) -> Result<String, DesktopGoogleOAuthError> {
        if wasCancelled { return .failure(.canceled) }
        guard let callbackURL, let result = result(from: callbackURL) else {
            return .failure(.invalidResponse)
        }
        return result
    }

    static func result(from callbackURL: URL) -> Result<String, DesktopGoogleOAuthError>? {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "hanasand",
              components.host?.lowercased() == "social",
              components.path.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1 else { return nil }

        let item = queryItems[0]
        if item.name == "code",
           let code = item.value,
           code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil {
            return .success(code)
        }
        if item.name == "error", let error = item.value, !error.isEmpty {
            return .failure(.provider(error))
        }
        return nil
    }
}

enum DesktopGoogleOAuthError: LocalizedError, Equatable {
    case insecureEndpoint
    case invalidChallenge
    case invalidResponse
    case couldNotStart
    case canceled
    case provider(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint: return "Google sign-in requires a secure HTTPS website."
        case .invalidChallenge, .invalidResponse: return "Google sign-in could not be completed."
        case .couldNotStart: return "The secure Google sign-in window could not be opened."
        case .canceled: return "Google sign-in was canceled."
        case .provider(let message), .server(let message): return message
        }
    }
}

private struct ExchangePayload: Encodable {
    let code: String
    let verifier: String
}
