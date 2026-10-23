import Foundation

private final class RepositoryWorkspaceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum RepositoryWorkspaceSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RepositoryWorkspaceRedirectBlocker(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > limit {
            throw RepositoryWorkspaceError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw RepositoryWorkspaceError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

struct RepositoryWorkspaceClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let userID: String
    private let token: String
    private let organizationID: String
    private let send: Sender

    init(apiBaseURL: URL, userID: String, token: String, organizationID: String = "",
         impersonationToken: String = "", impersonatingUserID: String = "", send: Sender? = nil) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryWorkspaceError.impersonationUnsupported
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw RepositoryWorkspaceError.invalidBaseURL
        }
        guard !user.isEmpty, !credential.isEmpty else { throw RepositoryWorkspaceError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil,
              organization.isEmpty || organization.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw RepositoryWorkspaceError.invalidCredentials
        }
        self.baseURL = apiBaseURL
        self.userID = user
        self.token = credential
        self.organizationID = organization
        self.send = send ?? { request in try await RepositoryWorkspaceSession.send(request, limit: RepositoryWorkspaceLimits.responseBytes) }
    }

    func loadWorkspace() async throws -> (projects: [RepositoryWorkspaceProject], files: [RepositoryWorkspaceFile]) {
        async let projects: [RepositoryWorkspaceProject] = request("projects/user/\(segment(userID))")
        async let files: [RepositoryWorkspaceFile] = request("share/user/\(segment(userID))")
        let (projectRows, fileRows) = try await (projects, files)
        guard projectRows.count <= RepositoryWorkspaceLimits.rows,
              fileRows.count <= RepositoryWorkspaceLimits.rows,
              Set(projectRows.map(\.alias)).count == projectRows.count,
              Set(fileRows.map(\.id)).count == fileRows.count else {
            throw RepositoryWorkspaceError.invalidResponse
        }
        try projectRows.forEach { try $0.validate() }
        try fileRows.forEach { try $0.validate() }
        return (projectRows.sorted { $0.lastUpdated > $1.lastUpdated }, fileRows.sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") })
    }

    func loadProject(alias: String) async throws -> RepositoryWorkspaceProjectDetail {
        guard !alias.isEmpty, alias.count <= 200 else { throw RepositoryWorkspaceError.invalidResponse }
        let detail: RepositoryWorkspaceProjectDetail = try await request("project/\(segment(alias))")
        try detail.validate()
        return detail
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw RepositoryWorkspaceError.invalidResponse
        }
        let url = baseURL.appendingAPIPath(path)
        guard url.scheme?.lowercased() == "https", url.host == baseURL.host, url.user == nil, url.password == nil else {
            throw RepositoryWorkspaceError.invalidBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !organizationID.isEmpty { request.setValue(organizationID, forHTTPHeaderField: "x-organization-id") }

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host else {
            throw RepositoryWorkspaceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw RepositoryWorkspaceError.requestFailed(http.statusCode) }
        guard data.count <= RepositoryWorkspaceLimits.responseBytes else { throw RepositoryWorkspaceError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RepositoryWorkspaceError.invalidResponse }
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}
