import CryptoKit
import SwiftUI

private enum NativeShareGitSyncMode: Equatable {
    case `import`
    case pull
}

private enum NativeShareWorkspaceSearchPanelError: LocalizedError {
    case accountChanged

    var errorDescription: String? {
        "The signed-in account changed. Refresh the workspace and search again."
    }
}

struct NativeShareWorkspacePanel: View {
    let context: NativeShareWorkspaceContext
    let initialPath: String?
    let onOpenChat: (() -> Void)?

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var collaboration = NativeShareCollaborationLiveSession()
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
    @State private var isPreviewVisible = false
    @State private var pendingCreateType: String?
    @State private var newItemName = ""
    @State private var gitSource = ""
    @State private var gitHubToken = ""
    @State private var gitHasCredential = false
    @State private var gitRepository: NativeShareGitRepository?
    @State private var gitStatus: NativeShareGitStatus?
    @State private var gitProgress: NativeShareGitWorkspaceProgress?
    @State private var gitError = ""
    @State private var gitMessage = ""
    @State private var gitCommitMessage = ""
    @State private var gitSelectedPaths = Set<String>()
    @State private var gitAutoPullMinutes = 0
    @State private var gitPending = false
    @State private var gitOperation = ""
    @State private var isTerminalOpen = false
    @State private var isSearchOpen = false
    @State private var searchQuery = ""
    @State private var searchReplacement = ""
    @State private var searchOptions = NativeShareWorkspaceSearchOptions()
    @State private var searchFiles: [NativeShareWorkspaceSearchFile] = []
    @State private var searchCacheScope = ""
    @State private var searchResponse: NativeShareWorkspaceSearchResponse?
    @State private var searchQuerySnapshot = ""
    @State private var searchOptionsSnapshot: NativeShareWorkspaceSearchOptions?
    @State private var searchError = ""
    @State private var searchStatus = ""
    @State private var isSearching = false
    @State private var isReplacing = false
    @State private var isReplaceConfirmationPresented = false

    init(alias: String, fileID: String? = nil, initialPath: String? = nil, isProject: Bool = false,
         initialChatOpen: Bool = false, createIfMissing: Bool = false,
         initialSearchOpen: Bool = false,
         initialTerminalOpen: Bool = false,
         onOpenChat: (() -> Void)? = nil) {
        context = NativeShareWorkspaceContext(alias: alias, fileID: fileID, isProject: isProject,
                                              initialChatOpen: initialChatOpen, createIfMissing: createIfMissing)
        self.initialPath = initialPath
        self.onOpenChat = onOpenChat
        _selectedFileID = State(initialValue: fileID ?? "")
        _isSearchOpen = State(initialValue: initialSearchOpen)
        _isTerminalOpen = State(initialValue: initialTerminalOpen)
    }

    private var selectedFile: NativeShareWorkspaceFile? { workspace?.selectedFile }
    private var previewURL: URL? {
        guard let workspace else { return nil }
        return NativeSharePreview.target(alias: workspace.root.alias, tree: workspace.tree,
                                         rootContent: workspace.root.content, activeContent: selectedFile?.content)
    }
    private var interactionPolicy: NativeShareWorkspaceInteractionPolicy {
        .make(hasUnresolvedSaveConflict: saveConflict != nil || (!context.isProject &&
            (collaboration.session?.conflict != nil
                || collaboration.session?.saveState != nil && collaboration.session?.saveState != .saved)))
    }
    private var canEdit: Bool {
        model.hasHanasandAuth && selectedFile?.locked != true
            && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
    }
    private var canSaveSelectedFileContent: Bool {
        NativeShareWorkspaceEditorPolicy.canSaveContent(isFolder: selectedFile?.type == "folder")
    }
    private var searchResultsAreCurrent: Bool {
        searchResponse != nil && searchQuerySnapshot == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            && searchOptionsSnapshot == searchOptions
    }
    private var searchCacheIdentity: String {
        func fingerprint(_ value: String) -> String {
            Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
        }
        return [
            context.alias,
            model.userIDForRequests,
            model.settings.impersonatingUserID,
            fingerprint(model.authTokenForRequests),
            fingerprint(model.settings.impersonationToken),
        ].joined(separator: "\u{1f}")
    }
    private var loadIdentity: String {
        [context.alias, context.fileID ?? "", context.isProject ? "project" : "share",
         context.initialChatOpen ? "chat" : "", context.createIfMissing ? "create" : "", initialPath ?? ""]
            .joined(separator: "\u{1f}")
    }
    private var collaborationIdentityKey: String {
        [selectedFile?.id ?? "", context.isProject ? "project" : "share", model.settings.apiBaseURL,
         model.userIDForRequests, model.authTokenForRequests, model.settings.impersonationToken,
         model.settings.impersonatingUserID].joined(separator: "\u{1f}")
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
                    if !context.isProject {
                        ActionButton(title: isSearchOpen ? "Hide search" : "Search files", icon: "magnifyingglass") {
                            isSearchOpen.toggle()
                            if !isSearchOpen { searchError = ""; searchStatus = "" }
                        }
                        ActionButton(title: isTerminalOpen ? "Hide terminal" : "Terminal", icon: "terminal") {
                            isTerminalOpen.toggle()
                        }
                    }
                    if previewURL != nil {
                        ActionButton(title: isPreviewVisible ? "Hide preview" : "Show preview", icon: "rectangle.on.rectangle") {
                            isPreviewVisible.toggle()
                        }
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
            if !context.isProject {
                if isSearchOpen { searchPanel }
                gitPanel
                if isTerminalOpen { terminalPanel }
            }
            if isPreviewVisible, let previewURL {
                NativeGroupPanel(title: "Live preview", subtitle: previewURL.host ?? "Share preview") {
                    NativeSharePreviewView(target: previewURL)
                }
            }
        }
        .task(id: loadIdentity) { await load() }
        .task(id: context.isProject ? "project" : "git-\(context.alias)") { await loadGitWorkspaceState() }
        .task(id: "git-autopull-\(context.alias)-\(gitAutoPullMinutes)") { await runAutomaticGitPulls() }
        .task(id: collaborationIdentityKey) { syncCollaboration() }
        .onChange(of: searchCacheIdentity) { _, identity in
            guard identity != searchCacheScope else { return }
            invalidateSearchCache(scope: identity)
        }
        .onReceive(collaboration.$session) { changed in
            guard !context.isProject, let changed, changed.identity == collaboration.session?.identity,
                  changed.conflict == nil, let file = selectedFile, file.id == changed.identity.shareID else { return }
            if draftContent != changed.localContent { draftContent = changed.localContent }
            baselineContent = changed.persistedContent
        }
        .onChange(of: draftContent) { _, content in
            guard !context.isProject, selectedFile?.id == collaboration.session?.identity.shareID else { return }
            collaboration.edit(content)
        }
        .onDisappear { collaboration.stop() }
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
        .confirmationDialog(
            "Replace matches across the workspace?",
            isPresented: $isReplaceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Replace All", role: .destructive) { Task { await replaceSearchMatches() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will update \(searchResponse?.totalMatches ?? 0) matches across \(searchResponse?.groups.count ?? 0) files. Each file is checked against its latest server copy before saving.")
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
                ActionButton(title: "New file", icon: "doc.badge.plus") { beginCreate(type: "file") }
                    .disabled(isSaving || pendingMutation != nil || !canEdit || !interactionPolicy.allowsNavigationAndTreeMutations)
                ActionButton(title: "New folder", icon: "folder.badge.plus") { beginCreate(type: "folder") }
                    .disabled(isSaving || pendingMutation != nil || !canEdit || !interactionPolicy.allowsNavigationAndTreeMutations)
            }
            if let pendingCreateType {
                VStack(alignment: .leading, spacing: 7) {
                    TextField(pendingCreateType == "folder" ? "Folder name" : "File name", text: $newItemName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await createItem(type: pendingCreateType, name: newItemName) } }
                    if creationHasCaseOnlyCollision {
                        Text("A name with different capitalization already exists here; some tools treat names as case-sensitive.")
                            .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    HStack {
                        ActionButton(title: "Create", icon: "plus") {
                            Task { await createItem(type: pendingCreateType, name: newItemName) }
                        }.disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        ActionButton(title: "Cancel", icon: "xmark") {
                            self.pendingCreateType = nil
                            newItemName = ""
                        }.disabled(isSaving)
                    }
                }
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

    private var gitPanel: some View {
        NativeGroupPanel(title: "Git source", subtitle: gitRepository.map { "\($0.fullName) · \($0.branch)" } ?? "Import or sync a GitHub repository into this share", fillsAvailableWidth: true) {
            TextField("GitHub repository URL or owner/repo", text: $gitSource)
                .textFieldStyle(.roundedBorder)
                .disabled(gitPending || !canEdit)
            SecureField("GitHub token for a private repository (optional)", text: $gitHubToken)
                .textFieldStyle(.roundedBorder)
                .disabled(gitPending || !canEdit)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ActionButton(title: gitPending && gitOperation == "import" ? "Importing…" : "Import repository", icon: "arrow.down.doc", expands: true) {
                        Task { await syncGitRepository(mode: .import) }
                    }
                    .disabled(gitPending || !canEdit || gitSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: gitPending && gitOperation == "pull" ? "Pulling…" : "Pull latest", icon: "arrow.down.circle", expands: true) {
                        Task { await syncGitRepository(mode: .pull) }
                    }
                    .disabled(gitPending || !canEdit || gitSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: gitPending && gitOperation == "status" ? "Checking…" : "Refresh status", icon: "arrow.clockwise", expands: true) {
                        Task { await refreshGitStatus() }
                    }
                    .disabled(gitPending || gitRepository == nil && gitSource.isEmpty)
                }
                VStack(spacing: 8) {
                    ActionButton(title: gitPending && gitOperation == "import" ? "Importing…" : "Import repository", icon: "arrow.down.doc", expands: true) {
                        Task { await syncGitRepository(mode: .import) }
                    }
                    .disabled(gitPending || !canEdit || gitSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: gitPending && gitOperation == "pull" ? "Pulling…" : "Pull latest", icon: "arrow.down.circle", expands: true) {
                        Task { await syncGitRepository(mode: .pull) }
                    }
                    .disabled(gitPending || !canEdit || gitSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: gitPending && gitOperation == "status" ? "Checking…" : "Refresh status", icon: "arrow.clockwise", expands: true) {
                        Task { await refreshGitStatus() }
                    }
                    .disabled(gitPending || gitRepository == nil && gitSource.isEmpty)
                }
            }
            if let gitProgress {
                let label = gitProgress.currentPath.map { "\(gitProgress.completedFiles)/\(gitProgress.totalFiles) · \($0)" }
                    ?? "Preparing \(gitProgress.totalFiles) files…"
                ProgressView(value: Double(gitProgress.completedFiles), total: Double(max(gitProgress.totalFiles, 1)))
                Text(label).font(.system(size: 11)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
            if !gitMessage.isEmpty {
                Text(gitMessage).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.green).textSelection(.enabled)
            }
            if !gitError.isEmpty { NativeNotice(message: gitError, title: "Git workspace", tone: .error) }
            if let gitStatus {
                HStack(spacing: 10) {
                    Text(gitStatus.branchSummary ?? "Working tree")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 4)
                    ActionButton(title: "Stage all", icon: "checkmark.circle") {
                        gitSelectedPaths = Set(gitStatus.files.map(\.path))
                    }
                    .disabled(gitPending || gitStatus.files.isEmpty)
                }
                if gitStatus.files.isEmpty {
                    NativeEmptyState(title: "No Git changes", message: "The repository has no changed files to stage.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(gitStatus.files) { file in
                                Toggle(isOn: Binding(get: { gitSelectedPaths.contains(file.path) }, set: { selected in
                                    if selected { gitSelectedPaths.insert(file.path) }
                                    else { gitSelectedPaths.remove(file.path) }
                                })) {
                                    HStack(spacing: 7) {
                                        Text("\(file.index)\(file.workingTree)")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(theme.accent).frame(width: 25, alignment: .leading)
                                        Text(file.path).font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .disabled(gitPending)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                    .padding(9)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    TextField("Commit message", text: $gitCommitMessage)
                        .textFieldStyle(.roundedBorder).disabled(gitPending)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ActionButton(title: gitPending && gitOperation == "commit" ? "Committing…" : "Commit staged", icon: "checkmark", expands: true) { Task { await commitGitChanges() } }
                                .disabled(gitPending || gitSelectedPaths.isEmpty || gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            ActionButton(title: gitPending && gitOperation == "push" ? "Pushing…" : "Push", icon: "arrow.up.circle", expands: true) { Task { await pushGitChanges() } }
                                .disabled(gitPending || gitRepository == nil)
                            if gitHasCredential || gitRepository?.credential.hasCredential == true {
                                ActionButton(title: "Remove GitHub token", icon: "key.slash", expands: true) { Task { await removeGitHubCredential() } }
                                    .disabled(gitPending || gitRepository == nil)
                            } else {
                                ActionButton(title: "Save GitHub token", icon: "key", expands: true) { Task { await saveGitHubCredential() } }
                                    .disabled(gitPending || gitRepository == nil || gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        VStack(spacing: 8) {
                            ActionButton(title: gitPending && gitOperation == "commit" ? "Committing…" : "Commit staged", icon: "checkmark", expands: true) { Task { await commitGitChanges() } }
                                .disabled(gitPending || gitSelectedPaths.isEmpty || gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            ActionButton(title: gitPending && gitOperation == "push" ? "Pushing…" : "Push", icon: "arrow.up.circle", expands: true) { Task { await pushGitChanges() } }
                                .disabled(gitPending || gitRepository == nil)
                            if gitHasCredential || gitRepository?.credential.hasCredential == true {
                                ActionButton(title: "Remove GitHub token", icon: "key.slash", expands: true) { Task { await removeGitHubCredential() } }
                                    .disabled(gitPending || gitRepository == nil)
                            } else {
                                ActionButton(title: "Save GitHub token", icon: "key", expands: true) { Task { await saveGitHubCredential() } }
                                    .disabled(gitPending || gitRepository == nil || gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Auto-pull")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                if canEdit {
                    Picker("Auto-pull interval", selection: $gitAutoPullMinutes) {
                        Text("Off").foregroundStyle(theme.text).tag(0)
                        Text("5 minutes").foregroundStyle(theme.text).tag(5)
                        Text("15 minutes").foregroundStyle(theme.text).tag(15)
                        Text("30 minutes").foregroundStyle(theme.text).tag(30)
                        Text("60 minutes").foregroundStyle(theme.text).tag(60)
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                    .onChange(of: gitAutoPullMinutes) { _, value in
                        UserDefaults.standard.set(value, forKey: gitAutoPullIntervalKey)
                    }
                } else {
                    Text("Off").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var terminalPanel: some View {
        let configuredAPIBaseURL = URL(string: model.settings.apiBaseURL)
        return NativeShareTerminalPanel(
            apiBaseURL: configuredAPIBaseURL ?? URL(string: "https://visual-fixture.invalid/api")!,
            alias: context.alias,
            userID: model.userIDForRequests.isEmpty ? "default" : model.userIDForRequests,
            connectionEnabled: configuredAPIBaseURL?.host?.hasSuffix(".invalid") == false,
            onClose: { isTerminalOpen = false }
        )
    }

    private var searchPanel: some View {
        NativeGroupPanel(title: "Search workspace", subtitle: "Find and replace text across share files") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    TextField("Search files", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await searchWorkspace() } }
                    ActionButton(title: isSearching ? "Searching…" : "Search", icon: "magnifyingglass", expands: true) {
                        Task { await searchWorkspace() }
                    }
                    .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace == nil)
                }
                VStack(spacing: 8) {
                    TextField("Search files", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await searchWorkspace() } }
                    ActionButton(title: isSearching ? "Searching…" : "Search", icon: "magnifyingglass", expands: true) {
                        Task { await searchWorkspace() }
                    }
                    .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace == nil)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    searchToggle("Match case", isOn: $searchOptions.caseSensitive)
                    searchToggle("Whole word", isOn: $searchOptions.wholeWord)
                    searchToggle("Regex", isOn: $searchOptions.regex)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    searchToggle("Match case", isOn: $searchOptions.caseSensitive)
                    searchToggle("Whole word", isOn: $searchOptions.wholeWord)
                    searchToggle("Regex", isOn: $searchOptions.regex)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    TextField("Include files or globs", text: $searchOptions.include)
                        .textFieldStyle(.roundedBorder)
                    TextField("Exclude files or globs", text: $searchOptions.exclude)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(spacing: 8) {
                    TextField("Include files or globs", text: $searchOptions.include)
                        .textFieldStyle(.roundedBorder)
                    TextField("Exclude files or globs", text: $searchOptions.exclude)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let response = searchResponse {
                HStack(spacing: 8) {
                    Text("\(response.totalMatches) matches in \(response.groups.count) files · scanned \(response.filesScanned)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if response.isTruncated {
                        Text("Narrow search to replace all matches")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                if response.groups.isEmpty {
                    NativeEmptyState(title: "No matches", message: "Try a broader query or adjust include/exclude filters.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(response.groups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.file.path)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    ForEach(group.matches.prefix(80)) { match in
                                        Button { Task { await openSearchMatch(match) } } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("\(match.line):\(match.column)")
                                                    .foregroundStyle(theme.accent)
                                                    .frame(width: 52, alignment: .leading)
                                                Text(match.preview)
                                                    .foregroundStyle(theme.textSecondary)
                                                    .lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .font(.system(size: 10, design: .monospaced))
                                            .padding(.vertical, 3)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
                if response.totalMatches > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            TextField("Replace with", text: $searchReplacement)
                                .textFieldStyle(.roundedBorder)
                            ActionButton(title: isReplacing ? "Replacing…" : "Replace All", icon: "arrow.left.arrow.right", expands: true) {
                                isReplaceConfirmationPresented = true
                            }
                            .disabled(isSearching || isReplacing || !canEdit || !interactionPolicy.allowsNavigationAndTreeMutations || response.isTruncated || !searchResultsAreCurrent)
                        }
                        VStack(spacing: 8) {
                            TextField("Replace with", text: $searchReplacement)
                                .textFieldStyle(.roundedBorder)
                            ActionButton(title: isReplacing ? "Replacing…" : "Replace All", icon: "arrow.left.arrow.right", expands: true) {
                                isReplaceConfirmationPresented = true
                            }
                            .disabled(isSearching || isReplacing || !canEdit || !interactionPolicy.allowsNavigationAndTreeMutations || response.isTruncated || !searchResultsAreCurrent)
                        }
                    }
                    if !searchResultsAreCurrent {
                        Text("Search again to confirm the current query and filters before replacing.")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            if !searchStatus.isEmpty {
                Text(searchStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.green).textSelection(.enabled)
            }
            if !searchError.isEmpty { NativeNotice(message: searchError, title: "Workspace search", tone: .error) }
        }
    }

    private func searchToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .disabled(isSearching || isReplacing)
    }

    private var editorPanel: some View {
        NativeGroupPanel(title: selectedFile?.type == "folder" ? "Folder details" : (selectedFile?.displayName ?? "File editor"), subtitle: selectedFile?.path ?? "Select a file from the tree") {
            if let selectedFile {
                if let conflict = collaboration.session?.conflict,
                   collaboration.session?.identity.shareID == selectedFile.id {
                    NativeNotice(message: "A collaborator changed this document while you had local edits. Review both versions before continuing.",
                                 title: "Review concurrent edit", tone: .info)
                    HStack(spacing: 8) {
                        ActionButton(title: "Use theirs", icon: "arrow.uturn.backward") {
                            collaboration.useRemoteConflict()
                            draftContent = conflict.remoteContent
                            baselineContent = conflict.remoteContent
                        }
                        ActionButton(title: "Keep mine", icon: "arrow.uturn.forward") {
                            collaboration.keepLocalConflict()
                        }
                    }
                } else if let saveConflict, saveConflict.id == selectedFile.id {
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
                        TextField("File name", text: $draftName).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || !interactionPolicy.allowsNavigationAndTreeMutations)
                        TextField("Path", text: $draftPath).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || !interactionPolicy.allowsNavigationAndTreeMutations)
                    }
                    VStack(spacing: 8) {
                        TextField("File name", text: $draftName).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || !interactionPolicy.allowsNavigationAndTreeMutations)
                        TextField("Path", text: $draftPath).textFieldStyle(.roundedBorder).disabled(!canEdit || isSaving || pendingMutation != nil || !interactionPolicy.allowsNavigationAndTreeMutations)
                    }
                }
                HStack(spacing: 8) {
                    if isRenamingName {
                        ActionButton(title: isSaving ? "Renaming…" : "Rename", icon: "pencil") { Task { await renameSelected() } }
                            .disabled(isSaving || pendingMutation != nil || !interactionPolicy.allowsNavigationAndTreeMutations || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ActionButton(title: "Cancel rename", icon: "xmark") {
                            draftName = selectedFile.name ?? selectedFile.displayName
                            isRenamingName = false
                        }.disabled(isSaving || !interactionPolicy.allowsNavigationAndTreeMutations)
                    }
                    if draftPath != (selectedFile.path ?? "") {
                        ActionButton(title: isSaving ? "Saving path…" : "Save path", icon: "folder") { Task { await updatePath() } }
                            .disabled(isSaving || pendingMutation != nil || !interactionPolicy.allowsNavigationAndTreeMutations || draftPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if selectedFile.type == "folder" {
                    NativeNotice(message: "Folder selected. You can rename it or update its path; folders do not have editable file content.", title: "Folder")
                } else {
                    TextEditor(text: $draftContent)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 350)
                        .padding(7)
                        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .disabled(!canEdit || isSaving || saveConflict != nil || collaboration.session?.conflict != nil || pendingMutation != nil)
                    HStack {
                        if selectedFile.locked == true {
                            Label("Locked", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.danger)
                        } else if !model.hasHanasandAuth {
                            Label("Read only · sign in to edit", systemImage: "lock.open").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        if context.isProject {
                            ActionButton(title: isSaving ? "Saving…" : "Save file", icon: "checkmark") { Task { await saveFile() } }
                                .disabled(isSaving || isLoading || !canEdit || !canSaveSelectedFileContent || pendingMutation != nil || saveConflict != nil)
                        } else {
                            Text(collaborationStatus)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                NativeEmptyState(title: "Select a file", message: "Choose a file from the workspace tree to view its contents.")
            }
        }
    }

    @MainActor private func load() async {
        guard !isLoading, interactionPolicy.allowsNavigationAndTreeMutations else { return }
        invalidateSearchCache(scope: searchCacheIdentity)
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
            if context.fileID == nil,
               let initialPath,
               let item = NativeShareWorkspaceRouteSelection.resolve(path: initialPath, tree: loaded.tree, rootName: loaded.root.name) {
                let selected: NativeShareWorkspaceFile
                if item.type == "folder" {
                    selected = NativeShareWorkspaceFile(id: item.id, name: item.name, path: nil, alias: item.alias,
                                                        content: nil, type: item.type, parent: item.parent, locked: nil)
                } else {
                    selected = try await client.loadFile(id: item.id)
                }
                apply(NativeShareWorkspace(root: loaded.root, tree: loaded.tree, selectedFile: selected))
            } else {
                apply(loaded)
            }
            status = context.createIfMissing ? "Workspace created." : "Workspace loaded."
            if context.initialChatOpen && !didOpenChat {
                didOpenChat = true
                if let onOpenChat { onOpenChat() }
                else { status = "Workspace loaded · chat context received." }
            }
        } catch {
            if let shareError = error as? NativeShareWorkspaceError {
                self.error = shareError.errorDescription ?? "The share workspace could not be loaded."
            } else if error is URLError {
                self.error = "The share service could not be reached. Check the connection and refresh."
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? "The share workspace could not be loaded."
            }
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
        syncCollaboration()
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
            syncCollaboration()
            error = ""
            status = "Loaded \(file.displayName)."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor private func saveFile() async {
        guard context.isProject, let selectedFile, canSaveSelectedFileContent, pendingMutation == nil else { return }
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
                    if current.name != name || current.path != path {
                        _ = try await client.updateMetadata(id: id, name: name, path: path)
                    }
                    if context.isProject {
                        _ = try await client.saveFile(id: id, name: name, path: path,
                                                      content: content, baselineContent: baselineContent)
                        status = "Saved \(name)."
                        pendingMutation = nil
                        apply(try await client.load(context: refreshContext))
                    } else {
                        guard selectedFile?.id == id, collaboration.session?.identity.shareID == id else {
                            throw NativeShareWorkspaceError.invalidRoute
                        }
                        collaboration.edit(content)
                        status = "Content queued for live save."
                        pendingMutation = nil
                    }
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
        guard selectedFile?.id == conflict.id else { return }
        if context.isProject {
            isSaving = true
            defer { isSaving = false }
            do {
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
            return
        }
        collaboration.keepReviewedLocalVersion(remoteContent: conflict.remoteFile.content ?? "",
                                               localContent: conflict.localContent)
        draftContent = conflict.localContent
        baselineContent = conflict.remoteFile.content ?? ""
        saveConflict = nil
        status = "Your reviewed version is queued for live save."
        error = ""
    }

    private var refreshContext: NativeShareWorkspaceContext {
        NativeShareWorkspaceContext(alias: context.alias, fileID: nil, isProject: context.isProject,
                                    initialChatOpen: false, createIfMissing: false)
    }

    private func contains(_ id: String, in tree: [NativeShareWorkspaceTreeItem]) -> Bool {
        tree.contains { $0.id == id || contains(id, in: $0.children ?? []) }
    }

    private var creationHasCaseOnlyCollision: Bool {
        return (try? NativeShareWorkspaceCreationDecision.make(
            name: newItemName,
            siblingNames: creationSiblings.map(\.name)
        ).hasCaseOnlyCollision) ?? false
    }

    private var creationSiblings: [NativeShareWorkspaceTreeItem] {
        guard let workspace else { return [] }
        if selectedParentFolderID == workspace.root.id { return workspace.tree }
        return findTreeItem(id: selectedParentFolderID, in: workspace.tree)?.children ?? []
    }

    private func findTreeItem(id: String, in items: [NativeShareWorkspaceTreeItem]) -> NativeShareWorkspaceTreeItem? {
        for item in items {
            if item.id == id { return item }
            if let found = findTreeItem(id: id, in: item.children ?? []) { return found }
        }
        return nil
    }

    private func beginCreate(type: String) {
        pendingCreateType = type
        newItemName = type == "folder" ? "New Folder" : "New File.md"
    }

    @MainActor private func searchWorkspace() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = searchOptions
        guard !query.isEmpty, !isSearching, let workspace else { return }
        let cacheScope = searchCacheIdentity
        if searchCacheScope != cacheScope { invalidateSearchCache(scope: cacheScope) }
        isSearching = true
        searchError = ""
        searchStatus = ""
        searchResponse = nil
        defer { isSearching = false }

        do {
            _ = try NativeShareWorkspaceSearch.search(files: [], query: query, options: searchOptions)
            let descriptors = searchDescriptors(in: workspace.tree)
                .filter { NativeShareWorkspaceSearchFile.isSearchablePath($0.path) }
                .filter {
                    NativeShareWorkspaceSearch.shouldSearch(
                        NativeShareWorkspaceSearchFile(id: $0.id, name: $0.name, path: $0.path, content: ""),
                        options: options
                    )
                }
            guard descriptors.count <= NativeShareWorkspaceSearchLimits.maximumFiles else {
                throw NativeShareWorkspaceSearchError.workspaceTooLarge
            }
            let activeFileID = selectedFile?.type == "folder" ? "" : (selectedFile?.id ?? "")
            let activeContent = draftContent
            let apiBaseURL = model.settings.cdnBaseURL.normalizedBaseURL
            let userID = model.userIDForRequests
            let token = model.authTokenForRequests
            let impersonationToken = model.settings.impersonationToken
            let impersonatingUserID = model.settings.impersonatingUserID
            var cachedByID: [String: NativeShareWorkspaceSearchFile] = [:]
            for cached in searchFiles { cachedByID[cached.id] = cached }
            var filesByID: [String: NativeShareWorkspaceSearchFile] = [:]
            for descriptor in descriptors {
                if descriptor.id == activeFileID {
                    filesByID[descriptor.id] = NativeShareWorkspaceSearchFile(
                        id: descriptor.id, name: descriptor.name, path: descriptor.path, content: activeContent
                    )
                } else if let cached = cachedByID[descriptor.id] {
                    filesByID[descriptor.id] = NativeShareWorkspaceSearchFile(
                        id: descriptor.id, name: descriptor.name, path: descriptor.path, content: cached.content
                    )
                }
            }
            var totalBytes = filesByID.values.reduce(0) { $0 + $1.content.utf8.count }
            guard totalBytes <= NativeShareWorkspaceSearchLimits.maximumTotalContentBytes else {
                throw NativeShareWorkspaceSearchError.workspaceTooLarge
            }
            let missing = descriptors.filter { filesByID[$0.id] == nil }
            let clientConcurrency = 8
            let fetched = try await withThrowingTaskGroup(of: (String, NativeShareWorkspaceSearchFile).self) { group in
                var nextIndex = 0
                let initialCount = min(clientConcurrency, missing.count)
                while nextIndex < initialCount {
                    let descriptor = missing[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        let client = try NativeShareWorkspaceClient(
                            apiBaseURL: apiBaseURL, userID: userID, token: token,
                            impersonationToken: impersonationToken, impersonatingUserID: impersonatingUserID
                        )
                        let file = try await client.loadFile(id: descriptor.id)
                        return (descriptor.id, NativeShareWorkspaceSearchFile(
                            id: descriptor.id, name: descriptor.name, path: descriptor.path,
                            content: file.content ?? ""
                        ))
                    }
                }
                var indexed: [String: NativeShareWorkspaceSearchFile] = [:]
                while let (id, file) = try await group.next() {
                    indexed[id] = file
                    totalBytes += file.content.utf8.count
                    guard totalBytes <= NativeShareWorkspaceSearchLimits.maximumTotalContentBytes else {
                        group.cancelAll()
                        throw NativeShareWorkspaceSearchError.workspaceTooLarge
                    }
                    if nextIndex < missing.count {
                        let descriptor = missing[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            let client = try NativeShareWorkspaceClient(
                                apiBaseURL: apiBaseURL, userID: userID, token: token,
                                impersonationToken: impersonationToken, impersonatingUserID: impersonatingUserID
                            )
                            let file = try await client.loadFile(id: descriptor.id)
                            return (descriptor.id, NativeShareWorkspaceSearchFile(
                                id: descriptor.id, name: descriptor.name, path: descriptor.path,
                                content: file.content ?? ""
                            ))
                        }
                    }
                }
                return indexed
            }
            for (id, file) in fetched { filesByID[id] = file }
            let loadedFiles = descriptors.compactMap { filesByID[$0.id] }
            guard searchCacheIdentity == cacheScope,
                  model.userIDForRequests == userID, model.authTokenForRequests == token else {
                throw NativeShareWorkspaceSearchPanelError.accountChanged
            }
            let response = try NativeShareWorkspaceSearch.search(files: loadedFiles, query: query, options: options)
            searchFiles = loadedFiles
            searchCacheScope = cacheScope
            searchResponse = response
            searchQuerySnapshot = query
            searchOptionsSnapshot = options
            searchStatus = response.isTruncated ? "Results limited to \(response.totalMatches). Narrow the search before replacing." : "Searched \(response.filesScanned) files."
        } catch {
            searchError = (error as? LocalizedError)?.errorDescription ?? "Search failed. Check the query, connection, or workspace files."
        }
    }

    @MainActor private func replaceSearchMatches() async {
        guard !isReplacing, !isSearching, canEdit,
              interactionPolicy.allowsNavigationAndTreeMutations,
              searchResultsAreCurrent,
              let response = searchResponse, response.totalMatches > 0, !response.isTruncated else { return }
        isReplacing = true
        searchError = ""
        searchStatus = ""
        defer { isReplacing = false }

        var savedFiles = 0
        var replacedMatches = 0
        do {
            let userID = model.userIDForRequests
            let token = model.authTokenForRequests
            let plans = try NativeShareWorkspaceSearch.replacementPlans(
                files: searchFiles, query: searchQuery, replacement: searchReplacement, options: searchOptions
            )
            guard !plans.isEmpty else {
                searchStatus = "No files changed."
                return
            }
            let client = try makeClient()
            for plan in plans {
                guard model.userIDForRequests == userID, model.authTokenForRequests == token else {
                    throw NativeShareWorkspaceSearchPanelError.accountChanged
                }
                let current = try await client.loadFile(id: plan.fileID)
                guard (current.content ?? "") == plan.originalContent else {
                    throw NativeShareWorkspaceError.saveConflict(current)
                }
                guard model.userIDForRequests == userID, model.authTokenForRequests == token else {
                    throw NativeShareWorkspaceSearchPanelError.accountChanged
                }
                _ = try await client.saveFile(
                    id: plan.fileID,
                    name: current.name ?? searchFiles.first(where: { $0.id == plan.fileID })?.name ?? "",
                    path: current.path ?? plan.path,
                    content: plan.replacementContent,
                    baselineContent: plan.originalContent
                )
                savedFiles += 1
                replacedMatches += plan.matchCount
                if let index = searchFiles.firstIndex(where: { $0.id == plan.fileID }) {
                    searchFiles[index] = NativeShareWorkspaceSearchFile(
                        id: searchFiles[index].id, name: searchFiles[index].name, path: searchFiles[index].path,
                        content: plan.replacementContent
                    )
                }
                searchResponse = try NativeShareWorkspaceSearch.search(
                    files: searchFiles, query: searchQuery, options: searchOptions
                )
            }
            let currentContext = NativeShareWorkspaceContext(
                alias: context.alias, fileID: selectedFileID.isEmpty ? nil : selectedFileID,
                isProject: false, initialChatOpen: false, createIfMissing: false
            )
            apply(try await client.load(context: currentContext))
            searchStatus = "Replaced \(replacedMatches) matches across \(savedFiles) files."
        } catch {
            if savedFiles > 0 {
                if let refreshed = try? await makeClient().load(context: NativeShareWorkspaceContext(
                    alias: context.alias, fileID: selectedFileID.isEmpty ? nil : selectedFileID,
                    isProject: false, initialChatOpen: false, createIfMissing: false
                )) { apply(refreshed) }
                searchStatus = "Replaced \(replacedMatches) matches across \(savedFiles) files before stopping."
            }
            searchError = (error as? LocalizedError)?.errorDescription ?? "Replace stopped because a workspace file could not be updated."
        }
    }

    @MainActor private func openSearchMatch(_ match: NativeShareWorkspaceSearchMatch) async {
        guard let item = findTreeItem(id: match.fileID, in: workspace?.tree ?? []) else { return }
        await select(item)
    }

    private func searchDescriptors(in tree: [NativeShareWorkspaceTreeItem]) -> [(id: String, name: String, path: String)] {
        func collect(_ items: [NativeShareWorkspaceTreeItem], prefix: String) -> [(id: String, name: String, path: String)] {
            items.flatMap { item in
                let path = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
                let descendants = collect(item.children ?? [], prefix: path)
                guard (item.type ?? "file") == "file" else { return descendants }
                return [(item.id, item.name, path)] + descendants
            }
        }
        let flattened = collect(tree, prefix: "")
        guard let firstRoot = flattened.first?.path.split(separator: "/").first.map(String.init),
              flattened.allSatisfy({ $0.path.hasPrefix("\(firstRoot)/") }) else { return flattened }
        return flattened.map { file in
            (file.id, file.name, String(file.path.dropFirst(firstRoot.count + 1)))
        }
    }

    @MainActor private func invalidateSearchCache(scope: String) {
        searchFiles = []
        searchResponse = nil
        searchQuerySnapshot = ""
        searchOptionsSnapshot = nil
        searchCacheScope = scope
    }

    private var gitSourceKey: String { "hanasand.desktop.git.source.\(context.alias)" }
    private var gitAutoPullIntervalKey: String { "hanasand.desktop.git.autoPullMinutes.\(context.alias)" }
    private var gitCredentialKey: String { "hanasand.desktop.git.hasCredential.\(context.alias)" }

    @MainActor private func loadGitWorkspaceState() async {
        guard !context.isProject else { return }
        gitSource = UserDefaults.standard.string(forKey: gitSourceKey) ?? ""
        gitHasCredential = UserDefaults.standard.bool(forKey: gitCredentialKey)
        gitAutoPullMinutes = UserDefaults.standard.integer(forKey: gitAutoPullIntervalKey)
        guard !gitSource.isEmpty, canEdit else { return }
        await refreshGitStatus(showErrors: false)
    }

    @MainActor private func runAutomaticGitPulls() async {
        guard !context.isProject, gitAutoPullMinutes > 0, !gitSource.isEmpty, canEdit else { return }
        let delay = UInt64(gitAutoPullMinutes) * 60 * 1_000_000_000
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await syncGitRepository(mode: .pull, automatic: true)
        }
    }

    @MainActor private func syncGitRepository(mode: NativeShareGitSyncMode, automatic: Bool = false) async {
        guard canEdit else { gitError = "Sign in to manage Git for this workspace."; return }
        let source = gitSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { gitError = "Enter a GitHub repository URL or owner/repo."; return }
        guard !gitPending else { return }
        gitPending = true
        gitOperation = mode == .import ? "import" : "pull"
        gitError = ""
        gitMessage = automatic ? "Auto-pulling the latest repository files…" : (mode == .import ? "Loading repository into this workspace…" : "Pulling the latest repository files…")
        gitProgress = nil
        defer { gitPending = false; gitOperation = "" }

        var attemptedRepository: NativeShareGitRepository?
        do {
            let client = try makeGitClient()
            let existingID = mode == .pull ? context.alias : nil
            var repository = try await client.importRepository(input: source, existingID: existingID,
                githubToken: gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : gitHubToken)
            attemptedRepository = repository
            try await client.persistRepository(repository.withSyncState(status: "syncing",
                lastSyncedAt: repository.lastSyncedAt, lastSyncError: nil))
            if !gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let credential = try await client.attachGitHubCredential(repositoryID: repository.id, githubToken: gitHubToken)
                repository = repository.withCredential(credential)
                attemptedRepository = repository
            }

            let workspace = try await NativeShareGitWorkspaceSync(workspaceClient: makeClient()).sync(
                repository: repository, alias: repository.id,
                createIfMissing: mode == .import,
                progress: { gitProgress = $0 }
            )
            let syncedAt = ISO8601DateFormatter().string(from: Date())
            try await client.persistRepository(repository.withSyncState(status: "ready",
                lastSyncedAt: syncedAt, lastSyncError: nil))
            gitRepository = repository
            gitSource = repository.sourceUrl.isEmpty ? source : repository.sourceUrl
            UserDefaults.standard.set(gitSource, forKey: "hanasand.desktop.git.source.\(repository.id)")
            UserDefaults.standard.set(repository.credential.hasCredential, forKey: "hanasand.desktop.git.hasCredential.\(repository.id)")
            gitHasCredential = repository.credential.hasCredential
            gitHubToken = ""
            gitProgress = nil
            if mode == .pull {
                apply(workspace)
                gitMessage = automatic ? "Repository auto-pulled." : "Repository pulled into the share."
                do {
                    gitStatus = try await client.loadStatus(repositoryID: context.alias, shareID: context.alias)
                    gitSelectedPaths = Set(gitStatus?.files.filter(\.selected).map(\.path) ?? [])
                } catch {
                    gitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } else {
                gitMessage = "Repository loaded. Opening the new share…"
                model.openNativeDashboard(path: "/s", label: repository.fullName, detailID: repository.id)
            }
        } catch {
            gitProgress = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            gitError = message
            gitMessage = ""
            if let repository = attemptedRepository {
                try? await makeGitClient().persistRepository(repository.withSyncState(status: "error",
                    lastSyncedAt: repository.lastSyncedAt, lastSyncError: message))
            }
        }
    }

    @MainActor private func refreshGitStatus(showErrors: Bool = true) async {
        guard canEdit, !gitPending else { return }
        gitPending = true
        gitOperation = "status"
        defer { gitPending = false; gitOperation = "" }
        do {
            let status = try await makeGitClient().loadStatus(repositoryID: context.alias, shareID: context.alias)
            gitStatus = status
            gitSelectedPaths = Set(status.files.map(\.path))
            gitError = ""
            gitMessage = status.files.isEmpty ? "No Git changes in this share." : "\(status.files.count) changed files ready to stage."
        } catch {
            if showErrors { gitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    @MainActor private func commitGitChanges() async {
        guard gitStatus != nil, !gitSelectedPaths.isEmpty, !gitPending else { return }
        gitPending = true
        gitOperation = "commit"
        defer { gitPending = false; gitOperation = "" }
        do {
            let result = try await makeGitClient().commit(repositoryID: context.alias, shareID: context.alias,
                message: gitCommitMessage, paths: Array(gitSelectedPaths).sorted())
            gitStatus = result.status
            gitSelectedPaths = Set(result.status.files.map(\.path))
            gitCommitMessage = ""
            gitMessage = "Committed \(result.commit)."
            gitError = ""
        } catch { gitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    @MainActor private func pushGitChanges() async {
        guard !gitPending else { return }
        gitPending = true
        gitOperation = "push"
        defer { gitPending = false; gitOperation = "" }
        do {
            gitStatus = try await makeGitClient().push(repositoryID: context.alias)
            gitSelectedPaths = Set(gitStatus?.files.map(\.path) ?? [])
            gitMessage = "Pushed repository changes."
            gitError = ""
        } catch { gitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    @MainActor private func saveGitHubCredential() async {
        guard !gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !gitPending else { return }
        gitPending = true
        defer { gitPending = false }
        do {
            let credential = try await makeGitClient().attachGitHubCredential(repositoryID: context.alias, githubToken: gitHubToken)
            gitRepository = gitRepository?.withCredential(credential)
            gitHasCredential = credential.hasCredential
            UserDefaults.standard.set(gitHasCredential, forKey: gitCredentialKey)
            gitHubToken = ""
            gitMessage = "GitHub credential saved."
            gitError = ""
        } catch { gitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    @MainActor private func removeGitHubCredential() async {
        guard !gitPending else { return }
        gitPending = true
        defer { gitPending = false }
        do {
            try await makeGitClient().removeGitHubCredential(repositoryID: context.alias)
            gitRepository = gitRepository?.withCredential(.init(provider: "github_pat", hasCredential: false,
                tokenHint: nil, attachedAt: nil, lastUsedAt: nil, lastValidatedAt: nil))
            gitHasCredential = false
            UserDefaults.standard.set(false, forKey: gitCredentialKey)
            gitMessage = "GitHub credential removed."
            gitError = ""
        } catch { gitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    @MainActor private func createItem(type: String, name: String) async {
        guard interactionPolicy.allowsNavigationAndTreeMutations,
              let root = workspace?.root else { return }
        do {
            let decision = try NativeShareWorkspaceCreationDecision.make(name: name, siblingNames: creationSiblings.map(\.name))
            isSaving = true
            defer { isSaving = false }
            let id = UUID().uuidString.lowercased()
            let parent = selectedParentFolderID.isEmpty ? root.id : selectedParentFolderID
            let parentPath = findPath(for: parent) ?? root.displayName
            let path = "\(parentPath)/\(decision.name)"
            let created = try await makeClient().createItem(id: id, name: decision.name, path: path,
                                                           content: type == "file" ? "" : "", parent: parent, type: type)
            pendingCreateType = nil
            newItemName = ""
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

    private func makeGitClient() throws -> NativeShareGitClient {
        try NativeShareGitClient(settings: model.settings)
    }

    @MainActor private func syncCollaboration() {
        guard !context.isProject, let file = selectedFile, file.type != "folder", canEdit,
              file.locked != true, model.hasHanasandAuth,
              !model.userIDForRequests.isEmpty, !model.authTokenForRequests.isEmpty else {
            collaboration.stop()
            return
        }
        collaboration.start(
            identity: NativeShareCollaborationIdentity(shareID: file.id, accountID: model.userIDForRequests),
            apiBaseURL: model.settings.apiBaseURL,
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            displayName: model.userIDForRequests,
            initialContent: file.content ?? ""
        )
    }

    private var collaborationStatus: String {
        guard let session = collaboration.session,
              session.identity.shareID == selectedFile?.id else { return "Live editing unavailable" }
        switch (collaboration.connection, session.saveState) {
        case (.connected, .saved): return "Live · saved"
        case (.connected, .saving): return "Live · saving…"
        case (.connected, .queued): return "Live · queued"
        case (.connecting, _): return "Connecting…"
        case (.disconnected, .queued): return "Offline · changes queued"
        case (.disconnected, _): return session.lastError ?? "Disconnected"
        }
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

enum NativeShareWorkspaceRouteSelection {
    static func initialPath(explicitFileID: String?, routeSection: String?) -> String? {
        explicitFileID == nil ? routeSection : nil
    }

    static func resolve(path: String, tree: [NativeShareWorkspaceTreeItem], rootName: String? = nil) -> NativeShareWorkspaceTreeItem? {
        var requested = path.split(separator: "/").map(String.init)
        if let rootName, requested.first == rootName { requested.removeFirst() }
        guard !requested.isEmpty else { return nil }

        func walk(_ items: [NativeShareWorkspaceTreeItem], prefix: [String] = []) -> NativeShareWorkspaceTreeItem? {
            for item in items {
                let current = prefix + [item.name]
                if current == requested { return item }
                if let match = walk(item.children ?? [], prefix: current) { return match }
            }
            return nil
        }
        return walk(tree)
    }
}

enum NativeShareWorkspaceEditorPolicy {
    static func canSaveContent(isFolder: Bool) -> Bool { !isFolder }
}
