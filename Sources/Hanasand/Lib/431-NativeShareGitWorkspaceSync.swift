import Foundation

struct NativeShareGitWorkspaceProgress: Equatable {
    let completedFiles: Int
    let totalFiles: Int
    let currentPath: String?
}

struct NativeShareGitWorkspaceSync {
    typealias ProgressHandler = (NativeShareGitWorkspaceProgress) -> Void

    private let workspaceClient: NativeShareWorkspaceClient

    init(workspaceClient: NativeShareWorkspaceClient) {
        self.workspaceClient = workspaceClient
    }

    func sync(repository: NativeShareGitRepository, alias: String,
              createIfMissing: Bool = false,
              progress: ProgressHandler? = nil) async throws -> NativeShareWorkspace {
        try repository.validate()
        guard alias == repository.id, NativeShareGitSafety.isIdentifier(alias),
              !repository.fullName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              repository.files.count <= NativeShareWorkspaceLimits.treeItems,
              Set(repository.files.map(\.path)).count == repository.files.count,
              repository.files.allSatisfy({ NativeShareGitSafety.isSafeRelativePath($0.path) }) else {
            throw NativeShareGitError.invalidResponse
        }
        let filePaths = Set(repository.files.map(\.path))
        let requiredFolderPaths = Self.parentPaths(of: filePaths)
        guard filePaths.isDisjoint(with: requiredFolderPaths) else { throw NativeShareGitError.invalidResponse }

        let context = NativeShareWorkspaceContext(alias: alias, fileID: nil, isProject: false,
                                                  initialChatOpen: false, createIfMissing: false)
        var workspace: NativeShareWorkspace
        if createIfMissing {
            let creationContext = NativeShareWorkspaceContext(alias: alias, fileID: nil, isProject: false,
                                                              initialChatOpen: false, createIfMissing: true)
            do {
                workspace = try await workspaceClient.load(context: creationContext)
            } catch NativeShareWorkspaceError.requestFailed(409) {
                workspace = try await workspaceClient.load(context: context)
            } catch let caught as NativeShareWorkspaceError {
                guard case .mutationUncertain = caught else { throw caught }
                let refreshed = try await workspaceClient.load(context: context)
                guard refreshed.root.id == repository.id else { throw caught }
                workspace = refreshed
            }
            if workspace.root.id == repository.id {
                workspace = try await workspaceClient.load(context: context)
            }
        } else {
            workspace = try await workspaceClient.load(context: context)
        }
        guard workspace.root.id == repository.id else { throw NativeShareGitError.invalidResponse }

        let desiredRootPath = repository.fullName
        if workspace.root.name != repository.name || workspace.root.path != desiredRootPath {
            do {
                _ = try await workspaceClient.updateMetadata(id: workspace.root.id,
                    name: repository.name, path: desiredRootPath)
            } catch let caught as NativeShareWorkspaceError {
                guard case .mutationUncertain = caught else { throw caught }
                let checked = try await workspaceClient.load(context: context)
                guard checked.root.name == repository.name, checked.root.path == desiredRootPath else { throw caught }
                workspace = checked
            }
            workspace = try await workspaceClient.load(context: context)
        }

        let initialTree = workspace.tree
        var entries = Self.pathIndex(initialTree)
        guard entries.values.allSatisfy({ ["file", "folder"].contains($0.type) }) else {
            throw NativeShareGitError.invalidResponse
        }
        var folderIDs = [String: String](uniqueKeysWithValues: entries.compactMap { path, entry in
            entry.type == "folder" ? (path, entry.id) : nil
        })
        folderIDs[""] = repository.id

        let requiredFolders = Set(repository.files.flatMap { file in
            let parts = file.path.split(separator: "/").dropLast().map(String.init)
            var paths: [String] = []
            if !parts.isEmpty {
                paths = (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
            }
            return paths
        }).sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0 < $1 : leftDepth < rightDepth
        }

        for folderPath in requiredFolders where folderIDs[folderPath] == nil {
            guard entries[folderPath] == nil else { throw NativeShareGitError.invalidResponse }
            let components = folderPath.split(separator: "/").map(String.init)
            guard let name = components.last else { throw NativeShareGitError.invalidResponse }
            let parentPath = components.dropLast().joined(separator: "/")
            guard let parentID = folderIDs[parentPath] else { throw NativeShareGitError.invalidResponse }
            let id = UUID().uuidString.lowercased()
            let item = try await createOrReconcile(id: id, name: name,
                path: "\(repository.fullName)/\(folderPath)", parent: parentID, type: "folder", context: context)
            folderIDs[folderPath] = item.id
            entries[folderPath] = item
        }

        progress?(.init(completedFiles: 0, totalFiles: repository.files.count, currentPath: nil))
        for (index, file) in repository.files.enumerated() {
            guard let name = file.path.split(separator: "/").last.map(String.init) else {
                throw NativeShareGitError.invalidResponse
            }
            let parentPath = file.path.split(separator: "/").dropLast().joined(separator: "/")
            guard let parentID = folderIDs[parentPath] else { throw NativeShareGitError.invalidResponse }
            if let existing = entries[file.path] {
                guard existing.type == "file" else { throw NativeShareGitError.invalidResponse }
                let remote = try await workspaceClient.loadFile(id: existing.id)
                if remote.content != file.content {
                    do {
                        _ = try await workspaceClient.saveFile(id: remote.id, name: name,
                            path: remote.path ?? "\(repository.fullName)/\(file.path)",
                            content: file.content, baselineContent: remote.content ?? "")
                    } catch let caught as NativeShareWorkspaceError {
                        guard case .mutationUncertain = caught else { throw caught }
                        let checked = try await workspaceClient.loadFile(id: remote.id)
                        guard checked.content == file.content else { throw caught }
                    }
                }
            } else {
                _ = try await createOrReconcile(id: UUID().uuidString.lowercased(), name: name,
                    path: "\(repository.fullName)/\(file.path)", parent: parentID, type: "file",
                    content: file.content, context: context)
            }
            progress?(.init(completedFiles: index + 1, totalFiles: repository.files.count, currentPath: file.path))
        }

        let nextFiles = Set(repository.files.map(\.path))
        let retainedFolders = Self.parentPaths(of: nextFiles)
        let stale = Self.staleEntries(initialTree, prefix: "", nextFiles: nextFiles, retainedFolders: retainedFolders)
        for item in stale.files {
            try await deleteOrReconcile(item, context: context)
        }
        for item in stale.folders.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
            try await deleteOrReconcile(item, context: context)
        }

        return try await workspaceClient.load(context: context)
    }

    private func createOrReconcile(id: String, name: String, path: String, parent: String,
                                   type: String, content: String = "",
                                   context: NativeShareWorkspaceContext) async throws -> NativeShareGitSyncEntry {
        func matching(_ tree: [NativeShareWorkspaceTreeItem]) -> NativeShareGitSyncEntry? {
            let indexed = Self.pathIndex(tree)
            for item in indexed.values where item.id == id && item.name == name && item.type == type
                && (item.parent == parent || item.parent.isEmpty) {
                return item
            }
            return nil
        }

        do {
            let created = try await workspaceClient.createItem(id: id, name: name, path: path,
                content: content, parent: parent, type: type)
            return NativeShareGitSyncEntry(id: created.id, name: created.name ?? name, path: path,
                parent: created.parent ?? parent, type: created.type ?? type, alias: created.alias)
        } catch NativeShareWorkspaceError.mutationUncertain {
            let refreshed = try await workspaceClient.load(context: context)
            if let found = matching(refreshed.tree) { return found }
            do {
                let retried = try await workspaceClient.createItem(id: id, name: name, path: path,
                    content: content, parent: parent, type: type)
                return NativeShareGitSyncEntry(id: retried.id, name: retried.name ?? name, path: path,
                    parent: retried.parent ?? parent, type: retried.type ?? type, alias: retried.alias)
            } catch NativeShareWorkspaceError.mutationUncertain {
                let verified = try await workspaceClient.load(context: context)
                if let found = matching(verified.tree) { return found }
                throw NativeShareWorkspaceError.mutationUncertain("repository sync create")
            }
        }
    }

    private func deleteOrReconcile(_ item: NativeShareGitSyncEntry,
                                   context: NativeShareWorkspaceContext) async throws {
        for attempt in 0..<2 {
            let current = try await workspaceClient.load(context: context)
            guard Self.pathIndex(current.tree)[item.path] != nil else { return }
            do {
                _ = try await workspaceClient.deleteItem(id: item.id)
            } catch NativeShareWorkspaceError.mutationUncertain {
                let checked = try await workspaceClient.load(context: context)
                if Self.pathIndex(checked.tree)[item.path] == nil { return }
                if attempt == 1 { throw NativeShareWorkspaceError.mutationUncertain("repository sync delete") }
            }
            let checked = try await workspaceClient.load(context: context)
            if Self.pathIndex(checked.tree)[item.path] == nil { return }
            if attempt == 1 { throw NativeShareWorkspaceError.mutationUncertain("repository sync delete") }
        }
    }

    private static func pathIndex(_ tree: [NativeShareWorkspaceTreeItem]) -> [String: NativeShareGitSyncEntry] {
        var result: [String: NativeShareGitSyncEntry] = [:]
        func visit(_ items: [NativeShareWorkspaceTreeItem], prefix: String) {
            for item in items {
                let path = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
                result[path] = NativeShareGitSyncEntry(id: item.id, name: item.name, path: path,
                    parent: item.parent ?? "", type: item.type ?? "file", alias: item.alias)
                visit(item.children ?? [], prefix: path)
            }
        }
        visit(tree, prefix: "")
        return result
    }

    private static func parentPaths(of files: Set<String>) -> Set<String> {
        var result = Set<String>()
        for file in files {
            let components = file.split(separator: "/")
            for depth in 1..<components.count {
                result.insert(components.prefix(depth).joined(separator: "/"))
            }
        }
        return result
    }

    private static func staleEntries(_ tree: [NativeShareWorkspaceTreeItem], prefix: String,
                                     nextFiles: Set<String>, retainedFolders: Set<String>) -> (files: [NativeShareGitSyncEntry], folders: [NativeShareGitSyncEntry]) {
        var files: [NativeShareGitSyncEntry] = []
        var folders: [NativeShareGitSyncEntry] = []
        for item in tree {
            let path = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
            let type = item.type ?? "file"
            let entry = NativeShareGitSyncEntry(id: item.id, name: item.name, path: path,
                parent: item.parent ?? "", type: type, alias: item.alias)
            if type == "folder" {
                let children = staleEntries(item.children ?? [], prefix: path,
                    nextFiles: nextFiles, retainedFolders: retainedFolders)
                files.append(contentsOf: children.files)
                folders.append(contentsOf: children.folders)
                if !retainedFolders.contains(path) { folders.append(entry) }
            } else if !nextFiles.contains(path) {
                files.append(entry)
            }
        }
        return (files, folders)
    }
}

private struct NativeShareGitSyncEntry {
    let id: String
    let name: String
    let path: String
    let parent: String
    let type: String
    let alias: String?
}

extension NativeShareGitRepository {
    func withSyncState(status: String, lastSyncedAt: String?, lastSyncError: String?) -> NativeShareGitRepository {
        NativeShareGitRepository(id: id, ownerId: ownerId, accessScope: accessScope, name: name,
            fullName: fullName, branch: branch, defaultBranch: defaultBranch, sourcePath: sourcePath,
            sourceUrl: sourceUrl, authMode: authMode, authHint: authHint, syncStatus: status,
            lastSyncedAt: lastSyncedAt, lastSyncError: lastSyncError, syncHistory: syncHistory,
            stackType: stackType, stackReason: stackReason, stackSupported: stackSupported,
            files: files, truncated: truncated, importedAt: importedAt, credential: credential)
    }

    func withCredential(_ credential: NativeShareGitCredential) -> NativeShareGitRepository {
        NativeShareGitRepository(id: id, ownerId: ownerId, accessScope: accessScope, name: name,
            fullName: fullName, branch: branch, defaultBranch: defaultBranch, sourcePath: sourcePath,
            sourceUrl: sourceUrl, authMode: authMode, authHint: authHint, syncStatus: syncStatus,
            lastSyncedAt: lastSyncedAt, lastSyncError: lastSyncError, syncHistory: syncHistory,
            stackType: stackType, stackReason: stackReason, stackSupported: stackSupported,
            files: files, truncated: truncated, importedAt: importedAt, credential: credential)
    }
}
