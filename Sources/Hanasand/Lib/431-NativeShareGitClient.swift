import Foundation

private final class NativeShareGitRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum NativeShareGitSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NativeShareGitRedirectBlocker(), delegateQueue: nil)
    }()
}

struct NativeShareGitClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let userID: String
    private let token: String
    private let send: Sender

    init(settings: HanasandDesktopSettings, send: Sender? = nil) throws {
        guard settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeShareGitError.impersonationUnsupported
        }
        let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !token.isEmpty else { throw NativeShareGitError.signInRequired }
        guard NativeShareGitSafety.isIdentifier(userID),
              token.utf8.count <= 4096,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw NativeShareGitError.invalidEndpoint
        }
        let apiURL = settings.apiBaseURL.normalizedBaseURL
        let resolvedAIURL = settings.resolvedAIEndpoint
        guard apiURL.scheme?.lowercased() == "https", apiURL.host != nil,
              apiURL.user == nil, apiURL.password == nil, apiURL.query == nil, apiURL.fragment == nil,
              resolvedAIURL.scheme?.lowercased() == "https", resolvedAIURL.host?.lowercased() == apiURL.host?.lowercased(),
              resolvedAIURL.user == nil, resolvedAIURL.password == nil,
              resolvedAIURL.query == nil, resolvedAIURL.fragment == nil else {
            throw NativeShareGitError.invalidEndpoint
        }
        self.baseURL = apiURL
        self.userID = userID
        self.token = token
        self.send = send ?? { request in try await NativeShareGitSession.shared.data(for: request) }
    }

    func importRepository(input: String, existingID: String? = nil, githubToken: String? = nil) async throws -> NativeShareGitRepository {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty, normalizedInput.utf8.count <= NativeShareGitLimits.fieldBytes,
              !normalizedInput.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              existingID.map(NativeShareGitSafety.isIdentifier) ?? true else { throw NativeShareGitError.invalidInput }
        let cleanToken = githubToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanToken {
            guard !cleanToken.isEmpty, cleanToken.utf8.count <= 4096,
                  !cleanToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw NativeShareGitError.invalidInput
            }
        }
        let payload = ImportPayload(input: normalizedInput, existingID: existingID, githubToken: cleanToken)
        let repository: NativeShareGitRepository = try await request("ai/import-repository", method: "POST", body: payload)
        try repository.validate(expectedOwnerID: userID)
        return repository
    }

    func persistRepository(_ repository: NativeShareGitRepository) async throws {
        try repository.validate(expectedOwnerID: userID)
        let response: NativeShareGitPersistResponse = try await request("ai/repositories", method: "POST", body: repository)
        guard response.ok, response.id == repository.id else { throw NativeShareGitError.invalidResponse }
    }

    func attachGitHubCredential(repositoryID: String, githubToken: String) async throws -> NativeShareGitCredential {
        try validateIdentifier(repositoryID)
        let cleanToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, cleanToken.utf8.count <= 4096,
              !cleanToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NativeShareGitError.invalidInput
        }
        let response: NativeShareGitCredentialResponse = try await request(
            "ai/repositories/\(segment(repositoryID))/credentials/github", method: "PUT",
            body: CredentialPayload(githubToken: cleanToken)
        )
        try response.credential.validate()
        return response.credential
    }

    func removeGitHubCredential(repositoryID: String) async throws {
        try validateIdentifier(repositoryID)
        let response: StatusResponse = try await request(
            "ai/repositories/\(segment(repositoryID))/credentials/github", method: "DELETE", body: Optional<NoBody>.none
        )
        guard response.ok else { throw NativeShareGitError.invalidResponse }
    }

    func loadStatus(repositoryID: String, shareID: String) async throws -> NativeShareGitStatus {
        try validateIdentifier(repositoryID)
        try validateIdentifier(shareID)
        var components = URLComponents(url: baseURL.appendingAPIPath("ai/repositories/\(segment(repositoryID))/git/status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "shareId", value: shareID)]
        guard let url = components?.url else { throw NativeShareGitError.invalidEndpoint }
        let status: NativeShareGitStatus = try await request(url: url, method: "GET", body: Optional<NoBody>.none)
        try status.validate()
        return status
    }

    func pull(repositoryID: String) async throws -> NativeShareGitStatus {
        try validateIdentifier(repositoryID)
        let status: NativeShareGitStatus = try await request(
            "ai/repositories/\(segment(repositoryID))/git/pull", method: "POST", body: Optional<NoBody>.none
        )
        try status.validate()
        return status
    }

    func commit(repositoryID: String, shareID: String, message: String, paths: [String]) async throws -> NativeShareGitCommitResponse {
        try validateIdentifier(repositoryID)
        try validateIdentifier(shareID)
        try NativeShareGitSafety.validateCommit(message: message, paths: paths)
        let response: NativeShareGitCommitResponse = try await request(
            "ai/repositories/\(segment(repositoryID))/git/commit", method: "POST",
            body: CommitPayload(shareID: shareID, message: message.trimmingCharacters(in: .whitespacesAndNewlines), paths: paths)
        )
        guard response.ok, !response.commit.isEmpty, response.commit.utf8.count <= 64 else { throw NativeShareGitError.invalidResponse }
        try response.status.validate()
        return response
    }

    func push(repositoryID: String) async throws -> NativeShareGitStatus {
        try validateIdentifier(repositoryID)
        let status: NativeShareGitStatus = try await request(
            "ai/repositories/\(segment(repositoryID))/git/push", method: "POST", body: Optional<NoBody>.none
        )
        try status.validate()
        return status
    }

    private func request<Response: Decodable, Body: Encodable>(_ path: String, method: String, body: Body?) async throws -> Response {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw NativeShareGitError.invalidInput }
        return try await request(url: baseURL.appendingAPIPath(path), method: method, body: body)
    }

    private func request<Response: Decodable, Body: Encodable>(url: URL, method: String, body: Body?) async throws -> Response {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == baseURL.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil else { throw NativeShareGitError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await send(request)
        guard data.count <= NativeShareGitLimits.responseBytes,
              let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == baseURL.host?.lowercased(),
              response.url?.user == nil, response.url?.password == nil else { throw NativeShareGitError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NativeShareGitError.requestFailed(http.statusCode) }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw NativeShareGitError.invalidResponse }
    }

    private func validateIdentifier(_ value: String) throws {
        guard NativeShareGitSafety.isIdentifier(value) else { throw NativeShareGitError.invalidInput }
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}

private struct ImportPayload: Encodable {
    let input: String
    let existingID: String?
    let githubToken: String?
    enum CodingKeys: String, CodingKey { case input, existingID = "existingId", githubToken }
}

private struct CredentialPayload: Encodable { let githubToken: String }
private struct CommitPayload: Encodable {
    let shareID: String
    let message: String
    let paths: [String]
    enum CodingKeys: String, CodingKey { case shareID = "shareId", message, paths }
}
private struct StatusResponse: Decodable { let ok: Bool }
private struct NoBody: Encodable {}
