import Foundation

private final class ServiceAccountRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url, to.scheme == "https", to.host == from.host, to.port == from.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum ServiceAccountsClientError: LocalizedError, Equatable {
    case signInRequired
    case invalidBaseURL
    case accessDenied
    case readOnly
    case invalidResponse
    case requestFailed(Int)
    case unknownOutcome

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view service accounts."
        case .invalidBaseURL: "Service accounts require a valid HTTPS API address."
        case .accessDenied: "Active Hanasand owner or editor access is required."
        case .readOnly: "Use your own Hanasand owner or editor account to make changes."
        case .invalidResponse: "The service accounts response could not be verified. Refresh and review current state."
        case let .requestFailed(status): "Service account request failed (HTTP \(status))."
        case .unknownOutcome: "The operation outcome is unknown. Refresh and review current accounts before another action."
        }
    }
}

struct ServiceAccountsClient {
    let baseURL: URL
    let userID: String
    let token: String
    let impersonationToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse)

    init(baseURL: URL, userID: String, token: String, impersonationToken: String = "", send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let cleanUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUserID.isEmpty, !cleanToken.isEmpty else { throw ServiceAccountsClientError.signInRequired }
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              cleanUserID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              cleanToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else { throw ServiceAccountsClientError.invalidBaseURL }
        let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components?.query == nil, components?.fragment == nil else { throw ServiceAccountsClientError.invalidBaseURL }
        self.baseURL = baseURL
        self.userID = cleanUserID
        self.token = cleanToken
        self.impersonationToken = impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let guardDelegate = ServiceAccountRedirectGuard()
            let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
            self.send = { try await Self.boundedSend($0, session: session) }
        }
    }

    func loadAccess() async throws -> ServiceAccountAccess {
        let response = try await request(path: "management/organizations?internalPages=1", method: "GET", body: nil, write: false)
        do {
            let access = try JSONDecoder().decode(ServiceAccountAccess.self, from: response.0)
            guard access.allowed else { throw ServiceAccountsClientError.accessDenied }
            return access
        } catch let error as ServiceAccountsClientError { throw error }
        catch { throw ServiceAccountsClientError.invalidResponse }
    }

    func loadDirectory() async throws -> ServiceAccountDirectory {
        let (data, _) = try await request(path: "service-accounts", method: "GET", body: nil, write: false)
        do {
            let result = try JSONDecoder().decode(ServiceAccountDirectory.self, from: data)
            guard Set(result.endpoints.map(\.id)).count == result.endpoints.count,
                  Set(result.accounts.map(\.id)).count == result.accounts.count,
                  result.accounts.allSatisfy({ account in account.keys.allSatisfy { key in key.ownerID == account.id && Set(key.scopes.map(\.id)).count == key.scopes.count } }) else { throw ServiceAccountsClientError.invalidResponse }
            return result
        } catch let error as ServiceAccountsClientError { throw error }
        catch { throw ServiceAccountsClientError.invalidResponse }
    }

    func create(access: ServiceAccountAccess, name: String, description: String, scopes: [ServiceAccountEndpoint]) async throws -> ServiceAccountReceipt {
        try requireWriter(access)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines), cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 100, cleanDescription.count <= 2000, !scopes.isEmpty, Set(scopes.map(\.id)).count == scopes.count else { throw ServiceAccountsClientError.invalidResponse }
        let allowed = try await loadDirectory().endpoints
        guard scopes.allSatisfy({ scope in allowed.contains(where: { $0.id == scope.id }) }) else { throw ServiceAccountsClientError.invalidResponse }
        let body: [String: Any] = ["name": cleanName, "description": cleanDescription, "scopes": scopes.map { ["method": $0.method, "route": $0.route] }]
        let (data, http) = try await request(path: "service-accounts", method: "POST", body: try JSONSerialization.data(withJSONObject: body), write: true)
        do {
            let receipt = try JSONDecoder().decode(ServiceAccountReceipt.self, from: data)
            guard http.statusCode == 201, receipt.apiKey.ownerID.hasPrefix("svc_"), receipt.apiKey.ownerID.count > 4,
                  receipt.apiKey.name == cleanName, receipt.apiKey.enabled,
                  receipt.secret.range(of: "^hsk_[a-f0-9]{12}_[a-f0-9]{48}$", options: .regularExpression) != nil,
                  receipt.apiKey.keyPrefix == receipt.secret.split(separator: "_").dropFirst().first.map(String.init),
                  Set(receipt.apiKey.scopes.map(\.id)) == Set(scopes.map(\.id)) else { throw ServiceAccountsClientError.unknownOutcome }
            return receipt
        } catch let error as ServiceAccountsClientError { throw error }
        catch { throw ServiceAccountsClientError.unknownOutcome }
    }

    func update(access: ServiceAccountAccess, id: String, name: String, description: String) async throws -> ServiceAccountUpdateReceipt {
        try requireWriter(access)
        let target = try validatedID(id), cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines), cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 100, cleanDescription.count <= 2000 else { throw ServiceAccountsClientError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["name": cleanName, "description": cleanDescription])
        let (data, _) = try await request(path: "service-accounts/\(target)", method: "PATCH", body: body, write: true)
        do { let receipt = try JSONDecoder().decode(ServiceAccountUpdateReceipt.self, from: data); guard receipt.id == target, receipt.name == cleanName, receipt.description == cleanDescription else { throw ServiceAccountsClientError.unknownOutcome }; return receipt }
        catch let error as ServiceAccountsClientError { throw error }
        catch { throw ServiceAccountsClientError.unknownOutcome }
    }

    func revoke(access: ServiceAccountAccess, id: String) async throws -> ServiceAccountRevokeReceipt {
        try requireWriter(access)
        let target = try validatedID(id)
        let (data, _) = try await request(path: "service-accounts/\(target)", method: "DELETE", body: nil, write: true)
        do { let receipt = try JSONDecoder().decode(ServiceAccountRevokeReceipt.self, from: data); guard !receipt.message.isEmpty else { throw ServiceAccountsClientError.unknownOutcome }; return receipt }
        catch let error as ServiceAccountsClientError { throw error }
        catch { throw ServiceAccountsClientError.unknownOutcome }
    }

    private func requireWriter(_ access: ServiceAccountAccess) throws {
        guard impersonationToken.isEmpty else { throw ServiceAccountsClientError.readOnly }
        guard access.allowed, access.canEdit else { throw ServiceAccountsClientError.readOnly }
    }

    private func validatedID(_ id: String) throws -> String {
        guard id.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil, id != ".", id != ".." else { throw ServiceAccountsClientError.invalidResponse }
        return id
    }

    private static func boundedSend(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw ServiceAccountsClientError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    private func request(path: String, method: String, body: Data?, write: Bool) async throws -> (Data, HTTPURLResponse) {
        if write && !impersonationToken.isEmpty { throw ServiceAccountsClientError.readOnly }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let prefix = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let pathPart = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        components?.percentEncodedPath = "/" + [prefix, pathPart].filter { !$0.isEmpty }.joined(separator: "/")
        components?.percentEncodedQuery = query
        guard let endpoint = components?.url, endpoint.scheme == "https", endpoint.host == baseURL.host else { throw ServiceAccountsClientError.invalidBaseURL }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == baseURL.host else { throw write ? ServiceAccountsClientError.unknownOutcome : ServiceAccountsClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                if write && http.statusCode >= 500 { throw ServiceAccountsClientError.unknownOutcome }
                throw ServiceAccountsClientError.requestFailed(http.statusCode)
            }
            guard data.count <= 8 * 1024 * 1024 else { throw write ? ServiceAccountsClientError.unknownOutcome : ServiceAccountsClientError.invalidResponse }
            return (data, http)
        } catch let error as ServiceAccountsClientError { throw error }
        catch { throw write ? ServiceAccountsClientError.unknownOutcome : error }
    }
}
