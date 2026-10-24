import Foundation

enum ChatGPTMembershipStatus: Equatable {
    case loading, member, nonmember, error(String)
}

struct ChatGPTPromptContextMessage: Encodable, Equatable {
    let role: String
    let content: String
    let modelName: String?
    let files: [FileReference]?

    struct FileReference: Encodable, Equatable {
        let itemId: String
        let fileId: String
    }

    init(role: String, content: String, modelName: String? = nil, files: [FileReference]? = nil) {
        self.role = role
        self.content = content
        self.modelName = modelName
        self.files = files
    }

    enum CodingKeys: String, CodingKey { case role, content, modelName, files }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(modelName, forKey: .modelName)
        try c.encodeIfPresent(files, forKey: .files)
    }
}

struct ChatGPTPromptPortalItem: Decodable, Equatable, Identifiable {
    let id: String
    let conversationId: String?
    let threadId: String?
    let prompt: String
    let status: String
    let priority: String
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let result: String?
    let files: [File]

    struct File: Decodable, Equatable, Identifiable {
        let id: String
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, conversationId, threadId, prompt, status, priority, createdAt, startedAt, completedAt, result, files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        status = try c.decode(String.self, forKey: .status)
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "next"
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        files = Array((try c.decodeIfPresent([File].self, forKey: .files) ?? []).prefix(50))
        guard ["queued", "running", "done", "error"].contains(status) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "ChatGPT returned an unsupported queue status.")
        }
    }
}

struct ChatGPTPromptPortalEnvelope: Decodable {
    let items: [ChatGPTPromptPortalItem]?
    let error: String?
}

struct ChatGPTOrganizationMembershipEnvelope: Decodable {
    struct Organization: Decodable {
        let slug: String?
        let lifecycleStatus: String?
        enum CodingKeys: String, CodingKey { case slug, lifecycleStatus, lifecycle_status }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slug = try c.decodeIfPresent(String.self, forKey: .slug)
            lifecycleStatus = try c.decodeIfPresent(String.self, forKey: .lifecycleStatus)
                ?? c.decodeIfPresent(String.self, forKey: .lifecycle_status)
        }
    }
    let organizations: [Organization]?
}

struct ChatGPTPromptPortalClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: LocalizedError {
        case signInRequired, impersonationUnsupported, invalidURL, invalidResponse, httpStatus(Int), responseError(String)
        var errorDescription: String? {
            switch self {
            case .signInRequired: return "Sign in to use ChatGPT in this conversation."
            case .impersonationUnsupported: return "ChatGPT is unavailable while impersonating another account."
            case .invalidURL: return "The configured Hanasand website URL is invalid."
            case .invalidResponse: return "The ChatGPT queue returned an invalid response."
            case .httpStatus(let status): return status == 401 || status == 403 ? "Your account cannot access the ChatGPT queue (HTTP \(status))." : "The ChatGPT queue returned HTTP \(status)."
            case .responseError(let message): return message
            }
        }
    }

    private let siteBaseURL: URL
    private let apiBaseURL: URL
    private let userID: String
    private let token: String
    private let send: Sender

    init(settings: HanasandDesktopSettings, send: Sender? = nil) throws {
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw ClientError.impersonationUnsupported }
        let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !token.isEmpty else { throw ClientError.signInRequired }
        guard let site = Self.httpsBase(settings.websiteBaseURL), let api = Self.organizationAPIBase(settings.apiBaseURL) else { throw ClientError.invalidURL }
        self.siteBaseURL = site
        self.apiBaseURL = api
        self.userID = userID
        self.token = token
        self.send = send ?? { request in try await ChatGPTPromptPortalSession.shared.data(for: request) }
    }

    func hasActiveHanasandMembership() async throws -> Bool {
        let url = apiBaseURL.appendingPathComponent("organizations", conformingTo: .url)
        let envelope: ChatGPTOrganizationMembershipEnvelope = try await get(url)
        guard let organizations = envelope.organizations else { throw ClientError.invalidResponse }
        return organizations.contains {
            $0.slug?.caseInsensitiveCompare("hanasand") == .orderedSame
                && (($0.lifecycleStatus ?? "").isEmpty || $0.lifecycleStatus?.caseInsensitiveCompare("active") == .orderedSame)
        }
    }

    func loadActivity(conversationID: String) async throws -> [ChatGPTPromptPortalItem] {
        let threadID = Self.threadID(conversationID)
        guard var components = URLComponents(url: siteBaseURL.appendingPathComponent("api/prompt"), resolvingAgainstBaseURL: false) else { throw ClientError.invalidURL }
        components.queryItems = [URLQueryItem(name: "conversationId", value: conversationID), URLQueryItem(name: "threadId", value: threadID)]
        guard let url = components.url else { throw ClientError.invalidURL }
        let envelope: ChatGPTPromptPortalEnvelope = try await get(url)
        guard let items = envelope.items else {
            if let error = envelope.error, !error.isEmpty { throw ClientError.responseError(error) }
            throw ClientError.invalidResponse
        }
        return items.filter { item in
            if let id = item.threadId { return id == threadID }
            return item.conversationId == conversationID
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    func submit(prompt: String, conversationID: String, context: [ChatGPTPromptContextMessage]) async throws -> [ChatGPTPromptPortalItem] {
        let url = siteBaseURL.appendingPathComponent("api/prompt")
        let boundary = "Hanasand-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyAuth(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart([
            ("prompt", prompt),
            ("conversationId", conversationID),
            ("threadId", Self.threadID(conversationID)),
            ("priority", "next"),
            ("context", String(data: try JSONEncoder().encode(context), encoding: .utf8) ?? "[]"),
        ], boundary: boundary)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ChatGPTPromptPortalEnvelope.self, from: data)
            throw envelope?.error.map(ClientError.responseError) ?? ClientError.httpStatus(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(ChatGPTPromptPortalEnvelope.self, from: data)
        guard let items = envelope.items else { throw ClientError.invalidResponse }
        let threadID = Self.threadID(conversationID)
        return items.filter { item in
            if let id = item.threadId { return id == threadID }
            return item.conversationId == conversationID
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    static func threadID(_ conversationID: String) -> String { "chatgpt-\(conversationID)" }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyAuth(to: &request)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ChatGPTPromptPortalEnvelope.self, from: data)
            throw envelope?.error.map(ClientError.responseError) ?? ClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func applyAuth(to request: inout URLRequest) {
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
    }

    private static func httpsBase(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    private static func organizationAPIBase(_ value: String) -> URL? {
        guard let base = httpsBase(value) else { return nil }
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.host?.caseInsensitiveCompare("api.hanasand.com") == .orderedSame && path == "api" {
            return URL(string: "https://identity.hanasand.com/api")
        }
        return base
    }

    private static func multipart(_ fields: [(String, String)], boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}

private final class ChatGPTPromptPortalRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum ChatGPTPromptPortalSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: ChatGPTPromptPortalRedirectBlocker(), delegateQueue: nil)
    }()
}
