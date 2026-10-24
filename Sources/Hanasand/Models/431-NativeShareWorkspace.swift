import Foundation

struct NativeShareWorkspaceFile: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let path: String?
    let alias: String?
    let content: String?
    let type: String?
    let parent: String?
    let locked: Bool?

    var displayName: String {
        [name, path, alias, id].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? id
    }

    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= NativeShareWorkspaceLimits.identifierBytes,
              (name?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.fieldBytes,
              (path?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.fieldBytes,
              (alias?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.fieldBytes,
              (content?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.contentBytes,
              (type?.utf8.count ?? 0) <= 50,
              (parent?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.identifierBytes else {
            throw NativeShareWorkspaceError.invalidResponse
        }
    }
}

struct NativeShareWorkspaceTreeItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let alias: String?
    let parent: String?
    let type: String?
    let children: [NativeShareWorkspaceTreeItem]?

    func validate(depth: Int = 0, count: inout Int) throws {
        count += 1
        guard count <= NativeShareWorkspaceLimits.treeItems,
              depth <= NativeShareWorkspaceLimits.treeDepth,
              !id.isEmpty, id.utf8.count <= NativeShareWorkspaceLimits.identifierBytes,
              !name.isEmpty, name.utf8.count <= NativeShareWorkspaceLimits.fieldBytes,
              (alias?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.identifierBytes,
              (parent?.utf8.count ?? 0) <= NativeShareWorkspaceLimits.identifierBytes,
              (type?.utf8.count ?? 0) <= 50,
              (children?.count ?? 0) <= NativeShareWorkspaceLimits.treeItems else {
            throw NativeShareWorkspaceError.invalidResponse
        }
        for child in children ?? [] { try child.validate(depth: depth + 1, count: &count) }
    }
}

struct NativeShareWorkspace: Equatable {
    let root: NativeShareWorkspaceFile
    let tree: [NativeShareWorkspaceTreeItem]
    let selectedFile: NativeShareWorkspaceFile?
}

struct NativeShareWorkspaceContext: Equatable {
    let alias: String
    let fileID: String?
    let isProject: Bool
    let initialChatOpen: Bool
    let createIfMissing: Bool
}

enum NativeShareWorkspaceLimits {
    static let responseBytes = 8 * 1024 * 1024
    static let contentBytes = 2 * 1024 * 1024
    static let fieldBytes = 4_096
    static let identifierBytes = 200
    static let treeItems = 3_000
    static let treeDepth = 32
}

enum NativeShareWorkspaceError: LocalizedError, Equatable {
    case signInRequired
    case impersonationUnsupported
    case invalidBaseURL
    case invalidRoute
    case invalidCredentials
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to create or edit workspace files."
        case .impersonationUnsupported: "Return to your own account to edit workspace files."
        case .invalidBaseURL: "Workspace files require a valid HTTPS API address."
        case .invalidRoute: "This workspace link is missing a valid project or file identifier."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidResponse: "The workspace service returned an invalid response."
        case .requestFailed(401): "Sign in again to open or edit this workspace."
        case .requestFailed(403): "The current account cannot edit this workspace."
        case .requestFailed(404): "This workspace or file was not found."
        case .requestFailed: "The workspace is unavailable. Refresh to try again."
        }
    }
}
