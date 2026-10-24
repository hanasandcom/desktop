import SwiftUI

struct RepositoryWorkspaceNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var projects: [RepositoryWorkspaceProject] = []
    @State private var files: [RepositoryWorkspaceFile] = []
    @State private var selectedAlias = ""
    @State private var selectedFileID = ""
    @State private var detail: RepositoryWorkspaceProjectDetail?
    @State private var projectPendingDeletion: RepositoryWorkspaceProject?
    @State private var search = ""
    @State private var error = ""
    @State private var isLoading = false

    private var visibleProjects: [RepositoryWorkspaceProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { query.isEmpty || "\($0.alias) \($0.owner)".localizedCaseInsensitiveContains(query) }
    }

    private var visibleFiles: [RepositoryWorkspaceFile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { query.isEmpty || "\($0.displayName) \($0.path ?? "") \($0.id)".localizedCaseInsensitiveContains(query) }
    }

    private var selectedFile: RepositoryWorkspaceFile? { files.first { $0.id == selectedFileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Repositories", subtitle: "Browse repositories and the files in your workspace") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        searchField
                        refreshButton
                        openSharesButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        searchField
                        HStack {
                            Spacer(minLength: 0)
                            refreshButton
                            openSharesButton
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    metric("Repositories", value: "\(projects.count)", icon: "folder")
                    metric("Files", value: "\(files.count)", icon: "doc.text")
                    metric("Total size", value: Self.byteCount(projects.reduce(Int64(0)) { $0 + $1.totalSize }), icon: "externaldrive")
                }

                if isLoading && projects.isEmpty && files.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading repositories and files…") }
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                if !error.isEmpty { NativeNotice(message: error) }
            }

            NativeGroupPanel(title: "Repository list", subtitle: "Sorted by most recent update") {
                if visibleProjects.isEmpty {
                    NativeEmptyState(title: projects.isEmpty ? "No repositories yet" : "No matching repositories",
                                     message: projects.isEmpty ? "Open Shares to manage workspace files." : "Try a different filter.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleProjects) { project in projectRow(project) }
                    }
                }

                if let detail, detail.share.id == selectedAlias || detail.share.alias == selectedAlias {
                    projectDetail(detail)
                }
            }

            NativeGroupPanel(title: "Files", subtitle: "Files available in the current workspace scope") {
                if visibleFiles.isEmpty {
                    NativeEmptyState(title: files.isEmpty ? "No files yet" : "No matching files",
                                     message: files.isEmpty ? "Add a file to make it available to your AI chats." : "Try a different filter.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleFiles) { file in fileRow(file) }
                    }
                }
                if let selectedFile, let content = selectedFile.content {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(selectedFile.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                            .lineLimit(2).textSelection(.enabled)
                        ScrollView([.horizontal, .vertical]) {
                            Text(content.isEmpty ? "This file has no content." : content)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                        .padding(10)
                        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .task { await refresh() }
        .confirmationDialog(
            "Delete repository?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete repository", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                Task { await deleteProject(project) }
            }
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
        } message: {
            if let project = projectPendingDeletion {
                Text("Permanently delete \(project.alias) and all files in its repository tree? This cannot be undone.")
            }
        }
    }

    private var searchField: some View {
        TextField("Filter repositories and files", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }

    private var refreshButton: some View {
        ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") {
            Task { await refresh() }
        }
        .disabled(isLoading || !model.hasHanasandAuth)
    }

    private var openSharesButton: some View {
        ActionButton(title: "Open shares", icon: "arrow.up.right") {
            model.openNativeDashboard(path: "/s", label: "Shares")
        }
        .disabled(!model.hasHanasandAuth)
    }

    private func projectRow(_ project: RepositoryWorkspaceProject) -> some View {
        ViewThatFits(in: .horizontal) {
            projectRowContent(project, stacked: false)
            projectRowContent(project, stacked: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func projectRowContent(_ project: RepositoryWorkspaceProject, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(theme.accent)
                    .frame(width: 28, height: 28)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.alias).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text("\(project.fileCount) files · \(Self.byteCount(project.totalSize)) · \(project.lastUpdated.isEmpty ? "No update time" : project.lastUpdated)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !stacked { Spacer(minLength: 4) }
            }

            HStack(spacing: 8) {
                if stacked { Spacer(minLength: 0) }
                ActionButton(title: isLoading && selectedAlias == project.alias ? "Loading…" : "Open", icon: "arrow.up.right") {
                    Task { await open(project) }
                }
                .disabled(isLoading)
                Button(role: .destructive) { projectPendingDeletion = project } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 34, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(theme.danger)
                .disabled(isLoading || !model.hasHanasandAuth)
                .accessibilityLabel("Delete repository \(project.alias)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectDetail(_ detail: RepositoryWorkspaceProjectDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(detail.share.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(detail.tree.count) top-level items")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            if detail.tree.isEmpty {
                Text("This repository has no files yet.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(detail.tree) { item in treeRow(item, depth: 0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .padding(10)
                .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.top, 8)
    }

    private func treeRow(_ item: RepositoryWorkspaceTreeItem, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.type == "folder" ? "folder" : "doc")
                        .foregroundStyle(item.type == "folder" ? theme.accent : theme.textTertiary)
                    Text(item.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, CGFloat(min(depth, 32)) * 14)
                ForEach(item.children ?? []) { child in treeRow(child, depth: depth + 1) }
            }
        )
    }

    private func fileRow(_ file: RepositoryWorkspaceFile) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: file.locked == true ? "lock.fill" : "doc.text")
                .foregroundStyle(file.locked == true ? theme.danger : theme.accent)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("\(file.locked == true ? "Locked" : "Open") · \(file.path ?? file.id)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if file.content != nil {
                Button(selectedFileID == file.id ? "Selected" : "Preview") { selectedFileID = file.id }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
            } else {
                Button("Open in Shares") {
                    model.openNativeDashboard(path: "/s", label: file.displayName)
                }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try RepositoryWorkspaceClient(
                apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                userID: model.settings.userID,
                token: model.settings.authToken,
                organizationID: model.selectedOrganizationID,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID
            )
            let workspace = try await client.loadWorkspace()
            projects = workspace.projects
            files = workspace.files
            if !projects.contains(where: { $0.alias == selectedAlias }) { selectedAlias = ""; detail = nil }
            if !files.contains(where: { $0.id == selectedFileID }) { selectedFileID = "" }
            error = ""
        } catch let issue { error = issue.localizedDescription }
    }

    @MainActor
    private func open(_ project: RepositoryWorkspaceProject) async {
        guard !isLoading else { return }
        isLoading = true
        selectedAlias = project.alias
        defer { isLoading = false }
        do {
            let client = try RepositoryWorkspaceClient(
                apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                userID: model.settings.userID,
                token: model.settings.authToken,
                organizationID: model.selectedOrganizationID,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID
            )
            detail = try await client.loadProject(alias: project.alias)
            error = ""
        } catch let issue { detail = nil; error = issue.localizedDescription }
    }

    @MainActor
    private func deleteProject(_ project: RepositoryWorkspaceProject) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try RepositoryWorkspaceClient(
                apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                userID: model.settings.userID,
                token: model.settings.authToken,
                organizationID: model.selectedOrganizationID,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID
            )
            try await client.deleteProject(alias: project.alias)
            projects.removeAll { $0.alias == project.alias }
            if selectedAlias == project.alias { selectedAlias = ""; detail = nil }
            error = "Deleted repository \(project.alias)."
        } catch {
            self.error = "Could not confirm deletion. Refresh the repository list before trying again. \(error.localizedDescription)"
        }
    }

    private static func byteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
