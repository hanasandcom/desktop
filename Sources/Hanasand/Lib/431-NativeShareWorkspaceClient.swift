import Foundation

private final class NativeShareWorkspaceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NativeShareWorkspaceClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    private let apiBaseURL: URL
    private let userID: String
    private let token: String
    private let sender: Sender

    init(apiBaseURL: URL, userID: String = "", token: String = "", impersonationToken: String = "",
         impersonatingUserID: String = "", sender: Sender? = nil) throws {
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeShareWorkspaceError.impersonationUnsupported
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw NativeShareWorkspaceError.invalidBaseURL
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (user.isEmpty && credential.isEmpty) || (Self.validCredential(user, max: 128) && Self.validCredential(credential, max: 4096)) else {
            throw NativeShareWorkspaceError.invalidCredentials
        }
        self.apiBaseURL = apiBaseURL
        self.userID = user
        self.token = credential
        self.sender = sender ?? Self.sendBounded
    }

    func load(context: NativeShareWorkspaceContext) async throws -> NativeShareWorkspace {
        guard Self.validIdentifier(context.alias),
              context.fileID.map(Self.validIdentifier) ?? true else { throw NativeShareWorkspaceError.invalidRoute }
        if context.createIfMissing {
            guard !userID.isEmpty else { throw NativeShareWorkspaceError.signInRequired }
            return try await createWorkspace(alias: context.alias)
        }
        if context.isProject {
            let detail: ProjectResponse = try await request("project/\(segment(context.alias))")
            try detail.share.validate()
            try Self.validateTree(detail.tree)
            let selected = try await loadSelectedFile(context.fileID, fallback: detail.share)
            return NativeShareWorkspace(root: detail.share, tree: detail.tree, selectedFile: selected)
        }

        let root: NativeShareWorkspaceFile = try await request("share/\(segment(context.alias))")
        try root.validate()
        let tree: [NativeShareWorkspaceTreeItem] = try await request("share/tree/\(segment(context.alias))")
        try Self.validateTree(tree)
        let selected = try await loadSelectedFile(context.fileID, fallback: root)
        return NativeShareWorkspace(root: root, tree: tree, selectedFile: selected)
    }

    func saveFile(id: String, name: String, path: String, content: String) async throws -> NativeShareWorkspaceFile {
        guard !userID.isEmpty else { throw NativeShareWorkspaceError.signInRequired }
        guard Self.validIdentifier(id), name.utf8.count <= NativeShareWorkspaceLimits.fieldBytes,
              path.utf8.count <= NativeShareWorkspaceLimits.fieldBytes,
              content.utf8.count <= NativeShareWorkspaceLimits.contentBytes else { throw NativeShareWorkspaceError.invalidRoute }
        let saved: NativeShareWorkspaceFile = try await mutationRequest("save", "share/\(segment(id))", method: "PUT", body: [
            "name": name, "path": path, "content": content,
        ])
        guard saved.id == id, saved.name == name, saved.path == path, saved.content == content else {
            throw NativeShareWorkspaceError.mutationUncertain("save")
        }
        try saved.validate()
        return saved
    }

    func updateMetadata(id: String, name: String? = nil, path: String? = nil) async throws -> NativeShareWorkspaceFile {
        guard !userID.isEmpty else { throw NativeShareWorkspaceError.signInRequired }
        guard Self.validIdentifier(id), name != nil || path != nil,
              (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true),
              (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true),
              (name?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.fieldBytes,
              (path?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.fieldBytes else {
            throw NativeShareWorkspaceError.invalidRoute
        }
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let path { body["path"] = path }
        let saved: NativeShareWorkspaceFile = try await mutationRequest("rename or move", "share/\(segment(id))", method: "PUT", body: body)
        guard saved.id == id, name == nil || saved.name == name, path == nil || saved.path == path else {
            throw NativeShareWorkspaceError.mutationUncertain("rename or move")
        }
        try saved.validate()
        return saved
    }

    func deleteItem(id: String) async throws -> Int {
        guard !userID.isEmpty else { throw NativeShareWorkspaceError.signInRequired }
        guard Self.validIdentifier(id) else { throw NativeShareWorkspaceError.invalidRoute }
        let receipt: NativeShareWorkspaceDeleteReceipt = try await mutationRequest("delete", "share/\(segment(id))", method: "DELETE")
        guard receipt.deleted > 0 else { throw NativeShareWorkspaceError.mutationUncertain("delete") }
        return receipt.deleted
    }

    func resumeDuplicate(_ plan: NativeShareWorkspaceDuplicatePlan, context: NativeShareWorkspaceContext) async throws -> NativeShareWorkspace {
        guard !userID.isEmpty else { throw NativeShareWorkspaceError.signInRequired }
        guard !plan.entries.isEmpty, plan.entries.count <= NativeShareWorkspaceLimits.treeItems,
              plan.entries.first?.id == plan.rootID else { throw NativeShareWorkspaceError.invalidRoute }

        let freshContext = NativeShareWorkspaceContext(alias: context.alias, fileID: nil, isProject: context.isProject,
                                                       initialChatOpen: false, createIfMissing: false)
        let current = try await load(context: freshContext)
        let existing = Self.flatten(current.tree)
        var completed = Set<String>()
        for entry in plan.entries {
            guard Self.validIdentifier(entry.id), Self.validIdentifier(entry.sourceID), Self.validIdentifier(entry.parentID),
                  ["file", "folder"].contains(entry.type), !entry.name.isEmpty,
                  entry.name.utf8.count <= NativeShareWorkspaceLimits.fieldBytes else {
                throw NativeShareWorkspaceError.invalidRoute
            }
            if let item = existing[entry.id] {
                guard item.name == entry.name, item.type == entry.type, item.parent == entry.parentID else {
                    throw NativeShareWorkspaceError.mutationUncertain("duplicate recovery")
                }
                completed.insert(entry.id)
            }
        }

        var contents: [String: String] = [:]
        for entry in plan.entries where entry.type == "file" && !completed.contains(entry.id) {
            let source = try await loadFile(id: entry.sourceID)
            guard source.type == nil || source.type == "file" else { throw NativeShareWorkspaceError.invalidResponse }
            contents[entry.id] = source.content ?? ""
        }
        for entry in plan.entries where !completed.contains(entry.id) {
            try await createDuplicate(entry, content: contents[entry.id] ?? "")
        }
        return try await load(context: freshContext)
    }

    func loadFile(id: String) async throws -> NativeShareWorkspaceFile {
        guard Self.validIdentifier(id) else { throw NativeShareWorkspaceError.invalidRoute }
        let file: NativeShareWorkspaceFile = try await request("share/\(segment(id))")
        try file.validate()
        return file
    }

    func createItem(id: String, name: String, path: String, content: String, parent: String, type: String) async throws -> NativeShareWorkspaceFile {
        guard !userID.isEmpty else { throw NativeShareWorkspaceError.signInRequired }
        guard Self.validIdentifier(id), Self.validIdentifier(parent),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= NativeShareWorkspaceLimits.fieldBytes,
              path.utf8.count <= NativeShareWorkspaceLimits.fieldBytes,
              content.utf8.count <= NativeShareWorkspaceLimits.contentBytes,
              ["file", "folder"].contains(type) else { throw NativeShareWorkspaceError.invalidRoute }
        let created: NativeShareWorkspaceFile = try await request("share", method: "POST", body: [
            "id": id, "name": name, "path": path, "content": content, "parent": parent,
            "type": type, "includeTree": false,
        ])
        try created.validate()
        return created
    }

    private func createWorkspace(alias: String) async throws -> NativeShareWorkspace {
        let created: CreatedWorkspaceResponse = try await request("share", method: "POST", body: [
            "id": alias, "name": alias, "path": alias, "content": "", "type": "folder", "includeTree": true,
        ])
        try created.share.validate()
        try Self.validateTree(created.tree ?? [])
        return NativeShareWorkspace(root: created.share, tree: created.tree ?? [], selectedFile: created.share)
    }

    private func loadSelectedFile(_ fileID: String?, fallback: NativeShareWorkspaceFile) async throws -> NativeShareWorkspaceFile {
        guard let fileID, fileID != fallback.id else { return fallback }
        let file: NativeShareWorkspaceFile = try await request("share/\(segment(fileID))")
        try file.validate()
        return file
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw NativeShareWorkspaceError.invalidRoute }
        if method != "GET", userID.isEmpty { throw NativeShareWorkspaceError.signInRequired }
        let url = apiBaseURL.appendingAPIPath(path)
        guard url.scheme?.lowercased() == "https", url.host == apiBaseURL.host, url.user == nil, url.password == nil else {
            throw NativeShareWorkspaceError.invalidBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !userID.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userID, forHTTPHeaderField: "id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await sender(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == apiBaseURL.host,
              response.url?.user == nil, response.url?.password == nil else { throw NativeShareWorkspaceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NativeShareWorkspaceError.requestFailed(http.statusCode) }
        guard data.count <= NativeShareWorkspaceLimits.responseBytes else { throw NativeShareWorkspaceError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NativeShareWorkspaceError.invalidResponse }
    }

    private func mutationRequest<T: Decodable>(_ action: String, _ path: String, method: String,
                                               body: [String: Any]? = nil) async throws -> T {
        do {
            return try await request(path, method: method, body: body)
        } catch let error as NativeShareWorkspaceError {
            if case let .requestFailed(status) = error, (400..<500).contains(status) { throw error }
            throw NativeShareWorkspaceError.mutationUncertain(action)
        } catch {
            throw NativeShareWorkspaceError.mutationUncertain(action)
        }
    }

    private func createDuplicate(_ entry: NativeShareWorkspaceDuplicateEntry, content: String) async throws {
        guard content.utf8.count <= NativeShareWorkspaceLimits.contentBytes else { throw NativeShareWorkspaceError.invalidResponse }
        let created: NativeShareWorkspaceFile = try await mutationRequest("duplicate", "share", method: "POST", body: [
            "id": entry.id, "name": entry.name, "content": content,
            "parent": entry.parentID, "type": entry.type, "includeTree": false,
        ])
        guard created.id == entry.id, created.name == entry.name,
              created.type == entry.type, created.parent == entry.parentID else {
            throw NativeShareWorkspaceError.mutationUncertain("duplicate")
        }
        try created.validate()
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= NativeShareWorkspaceLimits.identifierBytes
            && value.range(of: "^[A-Za-z0-9._~-]{1,200}$", options: .regularExpression) != nil
    }

    private static func validCredential(_ value: String, max: Int) -> Bool {
        value.utf8.count <= max && value.range(of: "^[A-Za-z0-9._~-]{1,\(max)}$", options: .regularExpression) != nil
    }

    private static func validateTree(_ tree: [NativeShareWorkspaceTreeItem]) throws {
        guard tree.count <= NativeShareWorkspaceLimits.treeItems else { throw NativeShareWorkspaceError.invalidResponse }
        var count = 0
        for item in tree { try item.validate(count: &count) }
    }

    private static func flatten(_ tree: [NativeShareWorkspaceTreeItem]) -> [String: NativeShareWorkspaceTreeItem] {
        var result: [String: NativeShareWorkspaceTreeItem] = [:]
        func visit(_ items: [NativeShareWorkspaceTreeItem]) {
            for item in items { result[item.id] = item; visit(item.children ?? []) }
        }
        visit(tree)
        return result
    }

    private static func sendBounded(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NativeShareWorkspaceRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > NativeShareWorkspaceLimits.responseBytes { throw NativeShareWorkspaceError.invalidResponse }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            guard data.count < NativeShareWorkspaceLimits.responseBytes else { throw NativeShareWorkspaceError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

private struct ProjectResponse: Decodable {
    let share: NativeShareWorkspaceFile
    let tree: [NativeShareWorkspaceTreeItem]
}

private struct CreatedWorkspaceResponse: Decodable {
    let share: NativeShareWorkspaceFile
    let tree: [NativeShareWorkspaceTreeItem]?

    enum CodingKeys: String, CodingKey {
        case id, name, path, alias, content, type, parent, locked, tree
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        share = NativeShareWorkspaceFile(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            path: try container.decodeIfPresent(String.self, forKey: .path),
            alias: try container.decodeIfPresent(String.self, forKey: .alias),
            content: try container.decodeIfPresent(String.self, forKey: .content),
            type: try container.decodeIfPresent(String.self, forKey: .type),
            parent: try container.decodeIfPresent(String.self, forKey: .parent),
            locked: try container.decodeIfPresent(Bool.self, forKey: .locked)
        )
        tree = try container.decodeIfPresent([NativeShareWorkspaceTreeItem].self, forKey: .tree)
    }
}

private struct NativeShareWorkspaceDeleteReceipt: Decodable {
    let deleted: Int
}
