import Foundation

struct RepositoryWorkspaceProject: Decodable, Identifiable, Equatable {
    let alias: String
    let owner: String
    let editors: [String]
    let fileCount: Int
    let totalSize: Int64
    let lastUpdated: String

    var id: String { alias }

    enum CodingKeys: String, CodingKey {
        case alias, owner, editors
        case fileCount = "file_count"
        case totalSize = "total_size"
        case lastUpdated = "last_updated"
    }

    func validate() throws {
        guard !alias.isEmpty, alias.count <= 200,
              owner.count <= 200,
              editors.count <= 100, editors.allSatisfy({ $0.count <= 200 }),
              (0...100_000).contains(fileCount),
              totalSize >= 0, totalSize <= 1_000_000_000_000,
              lastUpdated.count <= 100
        else { throw RepositoryWorkspaceError.invalidResponse }
    }
}

struct RepositoryWorkspaceFile: Decodable, Identifiable, Equatable {
    let id: String
    let path: String?
    let alias: String?
    let content: String?
    let timestamp: String?
    let locked: Bool?
    let owner: String?
    let parent: String?

    var displayName: String {
        [alias, path, id].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? id
    }

    enum CodingKeys: String, CodingKey {
        case id, path, alias, content, timestamp, locked, owner, parent
    }

    func validate() throws {
        guard !id.isEmpty, id.count <= 200,
              (path?.count ?? 0) <= 2_000,
              (alias?.count ?? 0) <= 200,
              (content?.utf8.count ?? 0) <= RepositoryWorkspaceLimits.fileBytes,
              (timestamp?.count ?? 0) <= 100,
              (owner?.count ?? 0) <= 200,
              (parent?.count ?? 0) <= 200
        else { throw RepositoryWorkspaceError.invalidResponse }
    }
}

struct RepositoryWorkspaceTreeItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let alias: String?
    let parent: String?
    let type: String?
    let children: [RepositoryWorkspaceTreeItem]?

    func validate(depth: Int = 0, total: inout Int) throws {
        total += 1
        guard total <= RepositoryWorkspaceLimits.treeItems,
              depth <= RepositoryWorkspaceLimits.treeDepth,
              !id.isEmpty, id.count <= 200,
              !name.isEmpty, name.count <= 2_000,
              (alias?.count ?? 0) <= 200,
              (parent?.count ?? 0) <= 200,
              (type?.count ?? 0) <= 50,
              (children?.count ?? 0) <= RepositoryWorkspaceLimits.treeItems
        else { throw RepositoryWorkspaceError.invalidResponse }
        for child in children ?? [] { try child.validate(depth: depth + 1, total: &total) }
    }
}

struct RepositoryWorkspaceProjectDetail: Decodable, Equatable {
    let share: RepositoryWorkspaceFile
    let tree: [RepositoryWorkspaceTreeItem]

    func validate() throws {
        try share.validate()
        guard tree.count <= RepositoryWorkspaceLimits.treeItems else {
            throw RepositoryWorkspaceError.invalidResponse
        }
        var total = 0
        for item in tree { try item.validate(total: &total) }
    }
}

enum RepositoryWorkspaceLimits {
    static let rows = 100
    static let responseBytes = 4 * 1024 * 1024
    static let fileBytes = 256 * 1024
    static let treeItems = 2_000
    static let treeDepth = 32
}

enum RepositoryWorkspaceError: LocalizedError, Equatable {
    case signInRequired
    case impersonationUnsupported
    case invalidBaseURL
    case invalidCredentials
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view repositories."
        case .impersonationUnsupported: "Return to your own account to view repositories."
        case .invalidBaseURL: "Repositories require a valid HTTPS API address."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidResponse: "The repository service returned an invalid response."
        case .requestFailed(401): "Sign in again to view repositories."
        case .requestFailed(403): "Current account does not have access to these repositories."
        case .requestFailed(404): "This repository or file is no longer available."
        case .requestFailed: "Repositories are unavailable. Refresh to try again."
        }
    }
}
