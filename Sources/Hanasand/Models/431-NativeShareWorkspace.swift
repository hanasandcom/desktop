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

struct NativeShareWorkspaceDuplicateEntry: Equatable, Identifiable {
    let sourceID: String
    let id: String
    let name: String
    let parentID: String
    let type: String

}

struct NativeShareWorkspaceDuplicatePlan: Equatable {
    let sourceID: String
    let rootID: String
    let entries: [NativeShareWorkspaceDuplicateEntry]

    static func make(
        sourceID: String,
        rootID: String,
        tree: [NativeShareWorkspaceTreeItem],
        makeID: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> NativeShareWorkspaceDuplicatePlan {
        guard !sourceID.isEmpty, !rootID.isEmpty else { throw NativeShareWorkspaceError.invalidRoute }

        func find(_ id: String, in items: [NativeShareWorkspaceTreeItem]) -> NativeShareWorkspaceTreeItem? {
            for item in items {
                if item.id == id { return item }
                if let found = find(id, in: item.children ?? []) { return found }
            }
            return nil
        }
        func siblings(_ id: String, in items: [NativeShareWorkspaceTreeItem]) -> [NativeShareWorkspaceTreeItem]? {
            for item in items {
                if item.id == id { return items }
                if let found = siblings(id, in: item.children ?? []) { return found }
            }
            return nil
        }
        func uniqueName(_ name: String, among items: [NativeShareWorkspaceTreeItem]) -> String {
            let names = Set(items.map(\.name))
            let extensionMatch = name.range(of: #"(\.[^./]+)$"#, options: .regularExpression)
            let suffix = extensionMatch.map { String(name[$0]) } ?? ""
            let base = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
            var candidate = "\(base) copy\(suffix)"
            var index = 2
            while names.contains(candidate) {
                candidate = "\(base) copy \(index)\(suffix)"
                index += 1
            }
            return candidate
        }

        guard let source = find(sourceID, in: tree),
              ["file", "folder"].contains(source.type ?? "file") else {
            throw NativeShareWorkspaceError.invalidRoute
        }
        let sourceSiblings = siblings(sourceID, in: tree) ?? tree
        var entries: [NativeShareWorkspaceDuplicateEntry] = []
        func append(_ item: NativeShareWorkspaceTreeItem, parentID: String, name: String) throws {
            let type = item.type ?? "file"
            guard ["file", "folder"].contains(type) else { throw NativeShareWorkspaceError.invalidResponse }
            let id = makeID().lowercased()
            guard id.range(of: #"^[a-f0-9-]{36}$"#, options: .regularExpression) != nil,
                  !entries.contains(where: { $0.id == id }) else {
                throw NativeShareWorkspaceError.invalidResponse
            }
            entries.append(NativeShareWorkspaceDuplicateEntry(sourceID: item.id, id: id, name: name, parentID: parentID, type: type))
            for child in item.children ?? [] { try append(child, parentID: id, name: child.name) }
        }
        try append(source, parentID: source.parent ?? rootID, name: uniqueName(source.name, among: sourceSiblings))
        guard !entries.isEmpty, entries.count <= NativeShareWorkspaceLimits.treeItems else {
            throw NativeShareWorkspaceError.invalidResponse
        }
        return NativeShareWorkspaceDuplicatePlan(sourceID: sourceID, rootID: entries[0].id, entries: entries)
    }
}

enum NativeShareWorkspacePendingMutation: Equatable {
    case delete(id: String, name: String)
    case metadata(id: String, name: String?, path: String?)
    case save(id: String, name: String, path: String, content: String)
    case duplicate(NativeShareWorkspaceDuplicatePlan)
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
    case mutationUncertain(String)
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to create or edit workspace files."
        case .impersonationUnsupported: "Return to your own account to edit workspace files."
        case .invalidBaseURL: "Workspace files require a valid HTTPS API address."
        case .invalidRoute: "This workspace link is missing a valid project or file identifier."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidResponse: "The workspace service returned an invalid response."
        case .mutationUncertain(let action): "The \(action) result could not be confirmed. Refresh the workspace before retrying."
        case .requestFailed(401): "Sign in again to open or edit this workspace."
        case .requestFailed(403): "The current account cannot edit this workspace."
        case .requestFailed(404): "This workspace or file was not found."
        case .requestFailed: "The workspace is unavailable. Refresh to try again."
        }
    }
}
