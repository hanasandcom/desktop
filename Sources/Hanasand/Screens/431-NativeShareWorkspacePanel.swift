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

    init(alias: String, fileID: String? = nil, isProject: Bool = false,
         initialChatOpen: Bool = false, createIfMissing: Bool = false,
         onOpenChat: (() -> Void)? = nil) {
        context = NativeShareWorkspaceContext(alias: alias, fileID: fileID, isProject: isProject,
                                              initialChatOpen: initialChatOpen, createIfMissing: createIfMissing)
        self.onOpenChat = onOpenChat
        _selectedFileID = State(initialValue: fileID ?? "")
    }

    private var selectedFile: NativeShareWorkspaceFile? { workspace?.selectedFile }
    private var canEdit: Bool { model.hasHanasandAuth && selectedFile?.locked != true }

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
                    }
                    ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }
                        .disabled(isLoading)
                }
                if !error.isEmpty { NativeNotice(message: error) }
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
            ForEach(item.children ?? []) { child in treeRow(child, depth: depth + 1) }
        })
    }

    private var treePanel: some View {
        NativeGroupPanel(title: "Workspace tree", subtitle: "Select a file to view or edit") {
            HStack(spacing: 8) {
                ActionButton(title: "New file", icon: "doc.badge.plus") { Task { await createItem(type: "file") } }
                    .disabled(isSaving || !model.hasHanasandAuth)
                ActionButton(title: "New folder", icon: "folder.badge.plus") { Task { await createItem(type: "folder") } }
                    .disabled(isSaving || !model.hasHanasandAuth)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        TextField("File name", text: $draftName).textFieldStyle(.roundedBorder)
                        TextField("Path", text: $draftPath).textFieldStyle(.roundedBorder)
                    }
                    VStack(spacing: 8) {
                        TextField("File name", text: $draftName).textFieldStyle(.roundedBorder)
                        TextField("Path", text: $draftPath).textFieldStyle(.roundedBorder)
                    }
                }
                TextEditor(text: $draftContent)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 350)
                    .padding(7)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .disabled(!canEdit)
                HStack {
                    if selectedFile.locked == true {
                        Label("Locked", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.danger)
                    } else if !model.hasHanasandAuth {
                        Label("Read only · sign in to edit", systemImage: "lock.open").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    ActionButton(title: isSaving ? "Saving…" : "Save file", icon: "checkmark") { Task { await saveFile() } }
                        .disabled(isSaving || isLoading || !canEdit)
                }
            } else {
                NativeEmptyState(title: "Select a file", message: "Choose a file from the workspace tree to view its contents.")
            }
        }
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
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
            workspace = loaded
            let selected = loaded.selectedFile
            selectedFileID = selected?.id ?? ""
            selectedParentFolderID = selected?.type == "folder" ? (selected?.id ?? loaded.root.id) : (selected?.parent ?? loaded.root.id)
            draftName = selected?.name ?? selected?.displayName ?? ""
            draftPath = selected?.path ?? ""
            draftContent = selected?.content ?? ""
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

    @MainActor private func select(_ item: NativeShareWorkspaceTreeItem) async {
        selectedFileID = item.id
        guard item.type != "folder" else {
            selectedParentFolderID = item.id
            if let root = workspace?.root, item.id == root.id {
                workspace = NativeShareWorkspace(root: root, tree: workspace?.tree ?? [], selectedFile: root)
                draftName = root.name ?? root.displayName
                draftPath = root.path ?? ""
                draftContent = root.content ?? ""
            }
            return
        }
        do {
            let file = try await makeClient().loadFile(id: item.id)
            selectedParentFolderID = file.parent ?? workspace?.root.id ?? ""
            workspace = NativeShareWorkspace(root: workspace?.root ?? file, tree: workspace?.tree ?? [], selectedFile: file)
            draftName = file.name ?? file.displayName
            draftPath = file.path ?? ""
            draftContent = file.content ?? ""
            error = ""
            status = "Loaded \(file.displayName)."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func saveFile() async {
        guard let selectedFile else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await makeClient().saveFile(id: selectedFile.id, name: draftName, path: draftPath, content: draftContent)
            workspace = NativeShareWorkspace(root: workspace?.root ?? saved, tree: workspace?.tree ?? [], selectedFile: saved)
            draftName = saved.name ?? draftName
            draftPath = saved.path ?? draftPath
            draftContent = saved.content ?? draftContent
            status = "Saved \(saved.displayName)."
            error = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func createItem(type: String) async {
        guard let root = workspace?.root else { return }
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
