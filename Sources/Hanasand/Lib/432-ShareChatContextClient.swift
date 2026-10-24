import Foundation

private final class ShareChatContextRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum ShareChatContextSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ShareChatContextRedirectBlocker(), delegateQueue: nil)
    }()
}

struct ShareChatContextClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: LocalizedError, Equatable {
        case signInRequired, impersonationUnsupported, invalidBaseURL, invalidShareID, invalidSelectedFilePath
        case invalidResponse, httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .signInRequired: return "Sign in to attach a share workspace to this AI conversation."
            case .impersonationUnsupported: return "Share workspace context is unavailable during account impersonation."
            case .invalidBaseURL: return "The configured share API endpoint is invalid."
            case .invalidShareID: return "The share identifier is invalid."
            case .invalidSelectedFilePath: return "The selected file is not part of this share workspace."
            case .invalidResponse: return "The share workspace returned an invalid response."
            case .httpStatus(let status): return status == 401 || status == 403 ? "Your session cannot access this share workspace." : "The share workspace returned HTTP \(status)."
            }
        }
    }

    private struct ShareFileEnvelope: Decodable {
        let id: String
        let path: String
        let content: String
    }

    private let baseURL: URL
    private let userID: String
    private let token: String
    private let send: Sender

    init(settings: HanasandDesktopSettings, send: Sender? = nil) throws {
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw ClientError.impersonationUnsupported }
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = settings.cdnBaseURL.normalizedBaseURL
        guard !user.isEmpty, !credential.isEmpty else { throw ClientError.signInRequired }
        guard base.scheme?.lowercased() == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              user.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              credential.range(of: #"^[A-Za-z0-9._~-]{1,4096}$"#, options: .regularExpression) != nil else {
            throw ClientError.invalidBaseURL
        }
        baseURL = base
        userID = user
        token = credential
        self.send = send ?? { request in try await ShareChatContextSession.shared.data(for: request) }
    }

    func load(shareID: String, selectedFileID: String? = nil, selectedFilePath: String? = nil,
              existingShareIDs: [String] = []) async throws -> ShareChatContext {
        guard ShareChatContext.validIdentifier(shareID) else { throw ClientError.invalidShareID }
        if let selectedFileID, !ShareChatContext.validIdentifier(selectedFileID) { throw ClientError.invalidSelectedFilePath }
        if let selectedFilePath, !ShareChatContext.validPath(selectedFilePath) { throw ClientError.invalidSelectedFilePath }

        let encodedShareID = try segment(shareID)
        let tree: [ShareChatTreeItem] = try await request("share/tree/\(encodedShareID)")
        let entries = flattened(tree)
        let treePaths = Array(entries.filter { $0.item.type == "file" }.map(\.path).prefix(100))
        let candidates = entries.filter { $0.item.type == "file" && ShareChatContext.validIdentifier($0.item.id) && ShareChatContext.validPath($0.path) }
        let selectedByID = selectedFileID.flatMap { id in candidates.first { $0.item.id == id } }
        let selectedByPath = selectedFilePath.flatMap { path in candidates.first { $0.path == path } }
        if selectedFileID != nil && selectedByID == nil || selectedFilePath != nil && selectedByPath == nil {
            throw ClientError.invalidSelectedFilePath
        }
        if let selectedByID, let selectedByPath, selectedByID.item.id != selectedByPath.item.id {
            throw ClientError.invalidSelectedFilePath
        }
        let selected = selectedByID ?? selectedByPath
        let focus = selected ?? candidates.first

        var fileTargets: [Entry] = []
        if let focus { fileTargets.append(focus) }
        for candidate in candidates where candidate.item.id != focus?.item.id {
            if fileTargets.count >= 5 { break }
            fileTargets.append(candidate)
        }

        var files: [ShareChatContextFile] = []
        for entry in fileTargets {
            let payload: ShareFileEnvelope = try await request("share/\(segment(entry.item.id))")
            guard payload.id == entry.item.id else { throw ClientError.invalidResponse }
            files.append(ShareChatContextFile(id: payload.id, path: entry.path, content: String(payload.content.prefix(entry.path == focus?.path ? 12_000 : 2_500))))
        }

        return ShareChatContext(
            shareID: shareID,
            workspaceId: shareID,
            workspaceKind: "share",
            shareIds: ShareChatContext.deduplicated([shareID] + existingShareIDs.filter(ShareChatContext.validIdentifier)),
            selectedFilePath: focus?.path,
            treePaths: treePaths,
            files: files
        )
    }

    private struct Entry {
        let item: ShareChatTreeItem
        let path: String
    }

    private func flattened(_ tree: [ShareChatTreeItem]) -> [Entry] {
        var result: [Entry] = []
        func walk(_ nodes: [ShareChatTreeItem], prefix: String, depth: Int) {
            guard depth <= 20, result.count < 500 else { return }
            for node in nodes {
                guard result.count < 500, !node.name.isEmpty, node.name.count <= 255,
                      !node.name.contains("/"), !node.name.contains("\\"), node.name != ".", node.name != ".." else { continue }
                let path = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
                guard ShareChatContext.validPath(path) else { continue }
                result.append(Entry(item: node, path: path))
                if node.type == "folder" { walk(node.children, prefix: path, depth: depth + 1) }
            }
        }
        walk(tree, prefix: "", depth: 0)
        return result
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ClientError.invalidShareID }
        let url = baseURL.appendingAPIPath(path)
        guard url.scheme?.lowercased() == "https", url.host == baseURL.host, url.user == nil, url.password == nil else {
            throw ClientError.invalidBaseURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        let (data, response) = try await send(request)
        guard data.count <= 4 * 1024 * 1024, let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ClientError.invalidResponse }
    }

    private func segment(_ value: String) throws -> String {
        guard ShareChatContext.validIdentifier(value),
              let safe = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            throw ClientError.invalidShareID
        }
        return safe
    }
}
