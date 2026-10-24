import SwiftUI

struct NativeShareWorkspacePanel: View {
    let context: NativeShareWorkspaceContext
    let onOpenChat: (() -> Void)?

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var workspace: NativeShareWorkspace?
    @State private var selectedFileID = ""
    @State private var selectedParentFolderID = ""
    @State private var draftName = ""
    @State private var draftPath = ""
    @State private var draftContent = ""
    @State private var error = ""
    @State private var status = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var didOpenChat = false
    @State private var isRenamingName = false
    @State private var pendingDeleteItem: NativeShareWorkspaceTreeItem?
    @State private var pendingMutation: NativeShareWorkspacePendingMutation?
    @State private var baselineContent = ""
    @State private var saveConflict: NativeShareWorkspaceSaveConflict?

    init(alias: String, fileID: String? = nil, isProject: Bool = false,
         initialChatOpen: Bool = false, createIfMissing: Bool = false,
         onOpenChat: (() -> Void)? = nil) {
        context = NativeShareWorkspaceContext(alias: alias, fileID: fileID, isProject: isProject,
                                              initialChatOpen: initialChatOpen, createIfMissing: createIfMissing)
        self.onOpenChat = onOpenChat
        _selectedFileID = State(initialValue: fileID ?? "")
    }

    private var selectedFile: NativeShareWorkspaceFile? { workspace?.selectedFile }
    private var interactionPolicy: NativeShareWorkspaceInteractionPolicy {
        .make(hasUnresolvedSaveConflict: saveConflict != nil)
    }
    private var canEdit: Bool {
        model.hasHanasandAuth && selectedFile?.locked != true
            && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: context.isProject ? "Project workspace" : "Share workspace",
                             subtitle: workspace?.root.displayName ?? context.alias) {
                HStack(spacing: 9) {
                    if isLoading { ProgressView().controlSize(.small) }
                    Text(status.isEmpty ? "Browse files and edit the selected share." : status)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if let onOpenChat {
                        ActionButton(title: "Open chat", icon: "bubble.left.and.bubble.right") { onOpenChat() }
                            .disabled(!interactionPolicy.allowsNavigationAndTreeMutations)
                    }
                    ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }
                        .disabled(isLoading || !interactionPolicy.allowsNavigationAndTreeMutations)
                }
                if !error.isEmpty { NativeNotice(message: error) }
                if let pendingMutation {
                    NativeNotice(message: "A workspace change may have reached the server. Refresh and safely resume the same action before making another change.", title: "Review pending change", tone: .info)
                    ActionButton(title: isSaving ? "Checking…" : "Check and resume change", icon: "arrow.clockwise") {
                        Task { await recover(pendingMutation) }
                    }
                    .disabled(isSaving || isLoading)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    treePanel.frame(minWidth: 280, idealWidth: 350, maxWidth: 440)
                    editorPanel.frame(minWidth: 430, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    treePanel.frame(maxWidth: .infinity)
                    editorPanel.frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: context) { await load() }
        .confirmationDialog(
            "Delete \(pendingDeleteItem?.name ?? "item")?",
            isPresented: Binding(get: { pendingDeleteItem != nil }, set: { if !$0 { pendingDeleteItem = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard interactionPolicy.allowsNavigationAndTreeMutations,
                      let item = pendingDeleteItem else { return }
                pendingDeleteItem = nil
                Task { await delete(item) }
            }
            Button("Cancel", role: .cancel) { pendingDeleteItem = nil }
        } message: {
            Text(pendingDeleteItem?.type == "folder"
                 ? "This removes the folder and every file or folder inside it."
                 : "This permanently removes this file from the share.")
        }
    }

    private func treeRow(_ item: NativeShareWorkspaceTreeItem, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            Button {
                Task { await select(item) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: item.type == "folder" ? "folder" : "doc.text")
                        .foregroundStyle(item.type == "folder" ? theme.accent : theme.textTertiary)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if selectedFileID == item.id { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, CGFloat(min(depth, 32)) * 13)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving || !interactionPolicy.allowsNavigationAndTreeMutations)
            .contextMenu {
                Button("Select to rename", systemImage: "pencil") {
                    Task { await select(item); isRenamingName = true }
                }
                .disabled(!canEdit || pendingMutation != nil || isSaving || !interactionPolicy.allowsNavigationAndTreeMutations)
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    Task { await duplicate(item) }
                }
                .disabled(!canEdit || pendingMutation != nil || isSaving || !interactionPolicy.allowsNavigationAndTreeMutations)
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDeleteItem = item }
                    .disabled(!canEdit || pendingMutation != nil || isSaving || !interactionPolicy.allowsNavigationAndTreeMutations)
            }
            ForEach(item.children ?? []) { child in treeRow(child, depth: depth + 1) }
        })
    }

    private var treePanel: some View {
        NativeGroupPanel(title: "Workspace tree", subtitle: "Select a file to view or edit") {
            HStack(spacing: 8) {
                ActionButton(title: "New file", icon: "doc.badge.plus") { Task { await createItem(type: "file") } }
                    .disabled(isSaving || pendingMutation != nil || !canEdit || !interactionPolicy.allowsNavigationAndTreeMutations)
                ActionButton(title: "New folder", icon: "folder.badge.plus") { Task { await createItem(type: "folder") } }
                    .disabled(isSaving || pendingMutation != nil || !canEdit || !interactionPolicy.allowsNavigationAndTreeMutations)
            }
            if let workspace, workspace.tree.isEmpty {
                NativeEmptyState(title: "No files yet", message: "Create a file or folder to add it to this workspace.")
            } else if let workspace {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(workspace.tree) { item in treeRow(item, depth: 0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 520)
                .padding(8)
                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if !isLoading {
                NativeEmptyState(title: "Workspace not loaded", message: "Refresh to load this project or share.")
            }
        }
    }

    private var editorPanel: some View {
        NativeGroupPanel(title: selectedFile?.displayName ?? "File editor", subtitle: selectedFile?.path ?? "Select a file from the tree") {
            if let selectedFile {
                if let saveConflict, saveConflict.id == selectedFile.id {
                    NativeNotice(
                        message: "The server copy differs from the version you opened. Keep mine will overwrite the displayed server copy after one more fresh check. The API has no atomic version check, so another edit could still race that write.",
                        title: "Review concurrent edit",
                        tone: .info
                    )
                    HStack(spacing: 8) {
                        ActionButton(title: "Use theirs", icon: "arrow.uturn.backward") {
                            useRemoteConflictVersion(saveConflict)
                        }.disabled(isSaving)
                        ActionButton(title: isSaving ? "Checking…" : "Keep mine", icon: "arrow.uturn.forward") {
                            Task { await keepLocalConflictVersion(saveConflict) }
                        }.disabled(isSaving || pendingMutation != nil)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        TextField("File name", text: $draftName).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || saveConflict != nil)
                        TextField("Path", text: $draftPath).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || saveConflict != nil)
                    }
                    VStack(spacing: 8) {
                        TextField("File name", text: $draftName).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || saveConflict != nil)
                        TextField("Path", text: $draftPath).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || saveConflict != nil)
                    }
                }
                HStack(spacing: 8) {
                    if isRenamingName {
                        ActionButton(title: isSaving ? "Renaming…" : "Rename", icon: "pencil") { Task { await renameSelected() } }
                            .disabled(isSaving || pendingMutation != nil || saveConflict != nil || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ActionButton(title: "Cancel rename", icon: "xmark") {
                            draftName = selectedFile.name ?? selectedFile.displayName
                            isRenamingName = false
                        }.disabled(isSaving || saveConflict != nil)
                    }
                    if draftPath != (selectedFile.path ?? "") {
                        ActionButton(title: isSaving ? "Saving path…" : "Save path", icon: "folder") { Task { await updatePath() } }
                            .disabled(isSaving || pendingMutation != nil || saveConflict != nil || draftPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                TextEditor(text: $draftContent)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 350)
                    .padding(7)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .disabled(!canEdit || isSaving || saveConflict != nil || pendingMutation != nil)
                HStack {
                    if selectedFile.locked == true {
                        Label("Locked", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.danger)
                    } else if !model.hasHanasandAuth {
                        Label("Read only · sign in to edit", systemImage: "lock.open").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    ActionButton(title: isSaving ? "Saving…" : "Save file", icon: "checkmark") { Task { await saveFile() } }
                        .disabled(isSaving || isLoading || !canEdit || pendingMutation != nil || saveConflict != nil)
                }
            } else {
                NativeEmptyState(title: "Select a file", message: "Choose a file from the workspace tree to view its contents.")
            }
        }
    }

    @MainActor private func load() async {
        guard !isLoading, interactionPolicy.allowsNavigationAndTreeMutations else { return }
        isLoading = true
        error = ""
        status = "Loading workspace…"
        defer { isLoading = false }
        do {
            let client = try makeClient()
            let requestContext = NativeShareWorkspaceContext(alias: context.alias, fileID: context.fileID,
                isProject: context.isProject, initialChatOpen: false,
                createIfMissing: context.createIfMissing && workspace == nil)
            let loaded = try await client.load(context: requestContext)
            apply(loaded)
            status = context.createIfMissing ? "Workspace created." : "Workspace loaded."
            if context.initialChatOpen && !didOpenChat {
                didOpenChat = true
                if let onOpenChat { onOpenChat() }
                else { status = "Workspace loaded · chat context received." }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = ""
        }
    }

    @MainActor private func apply(_ loaded: NativeShareWorkspace) {
        workspace = loaded
        let selected = loaded.selectedFile
        selectedFileID = selected?.id ?? ""
        selectedParentFolderID = selected?.type == "folder" ? (selected?.id ?? loaded.root.id) : (selected?.parent ?? loaded.root.id)
        draftName = selected?.name ?? selected?.displayName ?? ""
        draftPath = selected?.path ?? ""
        draftContent = selected?.content ?? ""
        baselineContent = selected?.content ?? ""
        saveConflict = nil
    }

    @MainActor private func select(_ item: NativeShareWorkspaceTreeItem) async {
        guard interactionPolicy.allowsNavigationAndTreeMutations, !isSaving else { return }
        selectedFileID = item.id
        guard item.type != "folder" else {
            selectedParentFolderID = item.id
            let folder = NativeShareWorkspaceFile(id: item.id, name: item.name, path: nil, alias: item.alias,
                                                  content: nil, type: item.type, parent: item.parent, locked: nil)
            workspace = NativeShareWorkspace(root: workspace?.root ?? folder, tree: workspace?.tree ?? [], selectedFile: folder)
            draftName = folder.name ?? folder.displayName
            draftPath = folder.path ?? ""
            draftContent = ""
            return
        }
        do {
            let file = try await makeClient().loadFile(id: item.id)
            selectedParentFolderID = file.parent ?? workspace?.root.id ?? ""
            workspace = NativeShareWorkspace(root: workspace?.root ?? file, tree: workspace?.tree ?? [], selectedFile: file)
            draftName = file.name ?? file.displayName
            draftPath = file.path ?? ""
            draftContent = file.content ?? ""
            baselineContent = file.content ?? ""
            saveConflict = nil
            error = ""
            status = "Loaded \(file.displayName)."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func saveFile() async {
        guard let selectedFile, pendingMutation == nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await makeClient().saveFile(id: selectedFile.id, name: draftName, path: draftPath,
                                                        content: draftContent, baselineContent: baselineContent)
            workspace = NativeShareWorkspace(root: workspace?.root ?? saved, tree: workspace?.tree ?? [], selectedFile: saved)
            draftName = saved.name ?? draftName
            draftPath = saved.path ?? draftPath
            draftContent = saved.content ?? draftContent
            baselineContent = saved.content ?? draftContent
            saveConflict = nil
            status = "Saved \(saved.displayName)."
            error = ""
            isRenamingName = false
        } catch {
            if let shareError = error as? NativeShareWorkspaceError, case let .saveConflict(remote) = shareError {
                recordSaveConflict(id: selectedFile.id, remote: remote)
            } else if error as? NativeShareWorkspaceError == .mutationUncertain("save") {
                pendingMutation = .save(id: selectedFile.id, name: draftName, path: draftPath,
                                        content: draftContent, baselineContent: baselineContent)
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func renameSelected() async {
        guard let selectedFile, pendingMutation == nil else { return }
        await updateMetadata(id: selectedFile.id, name: draftName.trimmingCharacters(in: .whitespacesAndNewlines), path: nil)
        if pendingMutation == nil { isRenamingName = false }
    }

    @MainActor private func updatePath() async {
        guard let selectedFile, pendingMutation == nil else { return }
        await updateMetadata(id: selectedFile.id, name: nil, path: draftPath.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor private func updateMetadata(id: String, name: String?, path: String?) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await makeClient().updateMetadata(id: id, name: name, path: path)
            apply(try await makeClient().load(context: refreshContext))
            status = name == nil ? "Path updated." : "Renamed \(name!)."
            error = ""
        } catch {
            if error as? NativeShareWorkspaceError == .mutationUncertain("rename or move") {
                pendingMutation = .metadata(id: id, name: name, path: path)
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func delete(_ item: NativeShareWorkspaceTreeItem) async {
        guard interactionPolicy.allowsNavigationAndTreeMutations, pendingMutation == nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await makeClient().deleteItem(id: item.id)
            let loaded = try await makeClient().load(context: refreshContext)
            guard !contains(item.id, in: loaded.tree) else { throw NativeShareWorkspaceError.mutationUncertain("delete") }
            pendingMutation = nil
            apply(loaded)
            status = "Deleted \(item.name)."
            error = ""
        } catch {
            if error as? NativeShareWorkspaceError == .mutationUncertain("delete") {
                pendingMutation = .delete(id: item.id, name: item.name)
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func duplicate(_ item: NativeShareWorkspaceTreeItem) async {
        guard interactionPolicy.allowsNavigationAndTreeMutations,
              let workspace, pendingMutation == nil else { return }
        do {
            let plan = try NativeShareWorkspaceDuplicatePlan.make(sourceID: item.id, rootID: workspace.root.id, tree: workspace.tree)
            pendingMutation = .duplicate(plan)
            await recover(.duplicate(plan))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func recover(_ mutation: NativeShareWorkspacePendingMutation) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let client = try makeClient()
            switch mutation {
            case let .delete(id, name):
                let fresh = try await client.load(context: refreshContext)
                guard contains(id, in: fresh.tree) else {
                    pendingMutation = nil
                    apply(fresh)
                    status = "Delete confirmed after refresh."
                    error = ""
                    return
                }
                _ = try await client.deleteItem(id: id)
                let verified = try await client.load(context: refreshContext)
                guard !contains(id, in: verified.tree) else { throw NativeShareWorkspaceError.mutationUncertain("delete") }
                pendingMutation = nil
                apply(verified)
                status = "Deleted \(name)."
                error = ""
            case let .metadata(id, name, path):
                let current = try await client.loadFile(id: id)
                if (name == nil || current.name == name) && (path == nil || current.path == path) {
                    status = "Change confirmed after refresh."
                } else {
                    _ = try await client.updateMetadata(id: id, name: name, path: path)
                    status = "Workspace details updated."
                }
                pendingMutation = nil
                error = ""
                apply(try await client.load(context: refreshContext))
            case let .save(id, name, path, content, baselineContent):
                let current = try await client.loadFile(id: id)
                if current.name == name && current.path == path && current.content == content {
                    status = "Save confirmed after refresh."
                    pendingMutation = nil
                    apply(try await client.load(context: refreshContext))
                } else {
                    guard (current.content ?? "") == baselineContent else {
                        pendingMutation = nil
                        saveConflict = NativeShareWorkspaceSaveConflict(
                            id: id, originalBaselineContent: baselineContent,
                            localName: name, localPath: path, localContent: content,
                            remoteFile: current
                        )
                        status = "The server copy changed while this save was unresolved. Choose Use theirs or Keep mine."
                        error = ""
                        return
                    }
                    _ = try await client.saveFile(id: id, name: name, path: path,
                                                  content: content, baselineContent: baselineContent)
                    status = "Saved \(name)."
                    pendingMutation = nil
                    apply(try await client.load(context: refreshContext))
                }
                error = ""
            case let .duplicate(plan):
                let loaded = try await client.resumeDuplicate(plan, context: refreshContext)
                pendingMutation = nil
                apply(loaded)
                status = "Duplicated item and confirmed the new tree."
                error = ""
            }
        } catch {
            if let shareError = error as? NativeShareWorkspaceError, case let .saveConflict(remote) = shareError,
               case let .save(id, name, path, content, baseline)? = pendingMutation {
                pendingMutation = nil
                saveConflict = NativeShareWorkspaceSaveConflict(
                    id: id, originalBaselineContent: baseline,
                    localName: name, localPath: path, localContent: content,
                    remoteFile: remote
                )
                status = "The server copy changed while this save was unresolved. Choose Use theirs or Keep mine."
                self.error = ""
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @MainActor private func recordSaveConflict(id: String, remote: NativeShareWorkspaceFile) {
        saveConflict = NativeShareWorkspaceSaveConflict(
            id: id,
            originalBaselineContent: baselineContent,
            localName: draftName,
            localPath: draftPath,
            localContent: draftContent,
            remoteFile: remote
        )
        status = "The server copy changed. Your draft is still here; choose Use theirs or Keep mine."
    }

    @MainActor private func useRemoteConflictVersion(_ conflict: NativeShareWorkspaceSaveConflict) {
        guard let current = workspace else { return }
        let remote = conflict.remoteFile
        workspace = NativeShareWorkspace(root: current.root, tree: current.tree, selectedFile: remote)
        selectedFileID = remote.id
        selectedParentFolderID = remote.parent ?? current.root.id
        draftName = remote.name ?? remote.displayName
        draftPath = remote.path ?? ""
        draftContent = remote.content ?? ""
        baselineContent = remote.content ?? ""
        saveConflict = nil
        pendingMutation = nil
        status = "Loaded the latest server version."
        error = ""
    }

    @MainActor private func keepLocalConflictVersion(_ conflict: NativeShareWorkspaceSaveConflict) async {
        guard saveConflict == conflict, pendingMutation == nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            // Treat the explicitly reviewed remote snapshot as the new baseline.
            // saveFile fetches it again before PUT; if it changed again, no PUT is sent.
            let remoteBaseline = conflict.remoteFile.content ?? ""
            let saved = try await makeClient().saveFile(
                id: conflict.id, name: conflict.localName, path: conflict.localPath,
                content: conflict.localContent, baselineContent: remoteBaseline
            )
            workspace = NativeShareWorkspace(root: workspace?.root ?? saved, tree: workspace?.tree ?? [], selectedFile: saved)
            draftName = saved.name ?? conflict.localName
            draftPath = saved.path ?? conflict.localPath
            draftContent = saved.content ?? conflict.localContent
            baselineContent = saved.content ?? conflict.localContent
            saveConflict = nil
            status = "Saved your reviewed version. The CDN has no atomic compare-and-swap protection."
            error = ""
        } catch {
            if let shareError = error as? NativeShareWorkspaceError, case let .saveConflict(remote) = shareError {
                saveConflict = NativeShareWorkspaceSaveConflict(
                    id: conflict.id, originalBaselineContent: conflict.originalBaselineContent,
                    localName: conflict.localName, localPath: conflict.localPath,
                    localContent: conflict.localContent, remoteFile: remote
                )
                status = "The server copy changed again. Your draft remains available; review the newest version."
            } else if error as? NativeShareWorkspaceError == .mutationUncertain("save") {
                pendingMutation = .save(id: conflict.id, name: conflict.localName, path: conflict.localPath,
                                        content: conflict.localContent, baselineContent: conflict.remoteFile.content ?? "")
                saveConflict = nil
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var refreshContext: NativeShareWorkspaceContext {
        NativeShareWorkspaceContext(alias: context.alias, fileID: nil, isProject: context.isProject,
                                    initialChatOpen: false, createIfMissing: false)
    }

    private func contains(_ id: String, in tree: [NativeShareWorkspaceTreeItem]) -> Bool {
        tree.contains { $0.id == id || contains(id, in: $0.children ?? []) }
    }

    @MainActor private func createItem(type: String) async {
        guard interactionPolicy.allowsNavigationAndTreeMutations,
              let root = workspace?.root else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let name = type == "folder" ? "New Folder" : "New File.md"
            let id = UUID().uuidString.lowercased()
            let parent = selectedParentFolderID.isEmpty ? root.id : selectedParentFolderID
            let parentPath = findPath(for: parent) ?? root.path ?? root.displayName
            let path = "\(parentPath)/\(name)"
            let created = try await makeClient().createItem(id: id, name: name, path: path,
                                                           content: type == "file" ? "" : "", parent: parent, type: type)
            status = "Created \(created.displayName). Refresh the tree to view it."
            error = ""
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func makeClient() throws -> NativeShareWorkspaceClient {
        try NativeShareWorkspaceClient(apiBaseURL: model.settings.cdnBaseURL.normalizedBaseURL,
                                       userID: model.userIDForRequests, token: model.authTokenForRequests,
                                       impersonationToken: model.settings.impersonationToken,
                                       impersonatingUserID: model.settings.impersonatingUserID)
    }

    private func findPath(for id: String) -> String? {
        func walk(_ items: [NativeShareWorkspaceTreeItem], prefix: String = "") -> String? {
            for item in items {
                let path = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
                if item.id == id { return path }
                if let nested = walk(item.children ?? [], prefix: path) { return nested }
            }
            return nil
        }
        return walk(workspace?.tree ?? [])
    }
}
