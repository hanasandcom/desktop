import Foundation

struct OrganizationApiKeyClient {
    let baseURL: URL
    let organizationID: String
    let userID: String
    let authToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings, organizationID: String, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let base = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw OrganizationApiKeyError.invalidBaseURL }

        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw OrganizationApiKeyError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw OrganizationApiKeyError.invalidCredentials
        }
        guard !organizationID.isEmpty, organizationID != "personal",
              settings.selectedOrganizationID == organizationID,
              settings.selectedOrganizationUserID == user else { throw OrganizationApiKeyError.organizationScopeChanged }
        guard settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationApiKeyError.impersonationUnsupported
        }

        self.baseURL = url
        self.organizationID = organizationID
        self.userID = user
        self.authToken = token
        if let send { self.send = send }
    }

    func list() async throws -> [OrganizationApiKey] {
        try await loadCurrentKeys()
    }

    func create(name: String) async throws -> OrganizationApiKeyCreateReceipt {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(cleanName.count) else { throw OrganizationApiKeyError.invalidName }

        // GET re-checks the caller's live membership and role. The server also repeats
        // that check transactionally when it handles the subsequent POST.
        _ = try await loadCurrentKeys()
        let body = try JSONEncoder().encode(NamePayload(name: cleanName))
        let receipt: OrganizationApiKeyCreateReceipt = try await request(
            path: "organizations/\(segment(organizationID))/api-keys",
            method: "POST",
            body: body
        )
        guard receipt.apiKey.organizationId == organizationID,
              receipt.apiKey.enabled,
              receipt.apiKey.name == cleanName,
              receipt.secret.range(of: "^hsk_[a-f0-9]{12}_[a-f0-9]{48}$", options: .regularExpression) != nil else {
            throw OrganizationApiKeyError.unconfirmedMutation
        }
        return receipt
    }

    func revoke(_ key: OrganizationApiKey) async throws -> OrganizationApiKey {
        guard key.organizationId == organizationID, key.enabled else { throw OrganizationApiKeyError.keyChanged }
        let current = try await loadCurrentKeys()
        guard current.contains(where: { $0.id == key.id && $0.enabled }) else { throw OrganizationApiKeyError.keyChanged }

        let receipt: OrganizationApiKeyRevokeReceipt = try await request(
            path: "organizations/\(segment(organizationID))/api-keys/\(segment(key.id))",
            method: "DELETE"
        )
        guard receipt.apiKey.organizationId == organizationID,
              receipt.apiKey.id == key.id,
              !receipt.apiKey.enabled else { throw OrganizationApiKeyError.unconfirmedMutation }
        return receipt.apiKey
    }

    private func loadCurrentKeys() async throws -> [OrganizationApiKey] {
        let envelope: OrganizationApiKeyList = try await request(
            path: "organizations/\(segment(organizationID))/api-keys",
            method: "GET"
        )
        guard envelope.organizationId == organizationID,
              envelope.apiKeys.allSatisfy({ $0.organizationId == organizationID }),
              Set(envelope.apiKeys.map(\.id)).count == envelope.apiKeys.count else {
            throw OrganizationApiKeyError.organizationScopeChanged
        }
        return envelope.apiKeys
    }

    private func request<T: Decodable>(path: String, method: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: try endpointURL(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw OrganizationApiKeyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ApiErrorEnvelope.self, from: data).error.message)
            throw OrganizationApiKeyError.requestFailed(http.statusCode, message ?? "Organization API-key request failed")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OrganizationApiKeyError.invalidResponse }
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private func endpointURL(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OrganizationApiKeyError.invalidResponse
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, path].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url, url.scheme == "https", url.host == baseURL.host else {
            throw OrganizationApiKeyError.invalidBaseURL
        }
        return url
    }

    private struct NamePayload: Encodable { let name: String }
    private struct ApiErrorEnvelope: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
}

enum OrganizationApiKeyError: LocalizedError {
    case invalidBaseURL
    case signInRequired
    case invalidCredentials
    case impersonationUnsupported
    case organizationScopeChanged
    case invalidName
    case keyChanged
    case unconfirmedMutation
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Organization API keys require a secure API URL."
        case .signInRequired: return "Sign in to manage organization API keys."
        case .invalidCredentials: return "The current account credentials are invalid. Sign in again."
        case .impersonationUnsupported: return "Return to your own account before managing API keys."
        case .organizationScopeChanged: return "Organization access changed. Refresh before continuing."
        case .invalidName: return "Key names must contain 2–80 characters."
        case .keyChanged: return "This key is no longer active in the selected organization. Refresh the list."
        case .unconfirmedMutation: return "The server did not confirm the requested key change. Refresh before retrying."
        case .invalidResponse: return "The organization API-key response was invalid."
        case let .requestFailed(status, message): return "Organization API returned HTTP \(status): \(message)"
        }
    }
}
