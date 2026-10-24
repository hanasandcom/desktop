import AppKit
import SwiftUI

struct CasesDevelopmentNativePanel: View {
    let caseID: String
    let organizationID: String?

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var entries: [CaseDevelopmentEntry] = []
    @State private var repositories: [CaseDevelopmentRepository] = []
    @State private var commits: [CaseDevelopmentCommit] = []
    @State private var cursor: String?
    @State private var selectedRepositoryID = ""
    @State private var search = ""
    @State private var provider = "forgejo"
    @State private var repositoryURL = ""
    @State private var setup: CaseDevelopmentRepositorySetup?
    @State private var pendingDisconnect: CaseDevelopmentRepository?
    @State private var isLoading = false
    @State private var isLoadingCommits = false
    @State private var isWriting = false
    @State private var error = ""
    @State private var notice = ""
    @State private var mutationNeedsReview = false
    @State private var reviewRefreshed = false

    private var activeOrganizationID: String? {
        let value = (organizationID ?? model.selectedOrganizationID).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "personal" ? nil : value
    }

    private var organizationCanManage: Bool {
        guard let activeOrganizationID else { return true }
        guard model.settings.impersonationToken.isEmpty,
              model.settings.impersonatingUserID.isEmpty else { return false }
        guard model.organizationDirectorySnapshotUserID == model.userIDForRequests else { return false }
        return model.organizationMemberships.first(where: { $0.id == activeOrganizationID && $0.status == "active" })
            .map { ["owner", "admin"].contains($0.role.lowercased()) } ?? false
    }

    private var selectedRepository: CaseDevelopmentRepository? {
        repositories.first(where: { $0.id == selectedRepositoryID }) ?? repositories.first
    }

    private var apiClient: CaseDevelopmentClient? {
        try? CaseDevelopmentClient(settings: model.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Code changes linked to this case")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isLoading || isWriting)
            }

            if mutationNeedsReview {
                NativeNotice(message: "A repository change may have completed without a confirmed response. Refresh the changes and connections, review them, then acknowledge before making another change.")
                HStack(spacing: 8) {
                    ActionButton(title: reviewRefreshed ? "Records refreshed" : "Refresh for review", icon: "arrow.clockwise") {
                        Task { await refreshForReview() }
                    }
                    .disabled(isLoading || isWriting || reviewRefreshed)
                    ActionButton(title: "Acknowledge review", icon: "checkmark.shield") {
                        mutationNeedsReview = false
                        reviewRefreshed = false
                        notice = "Review acknowledged. The previous repository mutation remains unconfirmed."
                    }
                    .disabled(!reviewRefreshed)
                }
            }

            if !error.isEmpty { NativeNotice(message: error, title: "Development unavailable", tone: .error) }
            if !notice.isEmpty { NativeNotice(message: notice, tone: .success) }

            if isLoading && entries.isEmpty && repositories.isEmpty {
                NativeEmptyState(title: "Loading development activity", message: "Retrieving linked commits, pull requests, and repository integrations.")
            } else if entries.isEmpty {
                NativeEmptyState(title: "No linked changes", message: "Link a repository commit to this case, or connect a repository to receive matching push and pull request activity.")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in developmentEntry(entry) }
                }
                if hasMore {
                    HStack { Spacer(); ActionButton(title: isLoading ? "Loading…" : "Load more changes", icon: "arrow.down") { Task { await loadMore() } }.disabled(isLoading || isWriting); Spacer() }
                }
            }

            commitLinkingPanel
            repositoryConnectionsPanel
            if let setup { webhookSecretPanel(setup) }
        }
        .task(id: "\(caseID):\(activeOrganizationID ?? "personal"):\(model.userIDForRequests)") {
            entries = []; repositories = []; commits = []; cursor = nil; setup = nil
            currentPageHasMore = false; mutationNeedsReview = false; reviewRefreshed = false
            await refresh()
        }
        .confirmationDialog("Disconnect repository?", isPresented: Binding(
            get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }
        ), titleVisibility: .visible) {
            Button("Disconnect and remove case links", role: .destructive) {
                guard let repository = pendingDisconnect else { return }
                pendingDisconnect = nil
                Task { await disconnect(repository) }
            }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: {
            Text("Disconnecting removes the repository’s case links from Hanasand. It does not change the repository or its webhook settings.")
        }
    }

    private var hasMore: Bool { currentPageHasMore }

    @State private var currentPageHasMore = false

    private func developmentEntry(_ entry: CaseDevelopmentEntry) -> some View {
        NativeGroupPanel(title: entry.kind == "commit" ? "Commit · \(String(entry.externalID.prefix(8)))" : "Pull request · \(entry.externalID)", subtitle: "\(entry.provider.capitalized) · \(entry.state.capitalized)") {
            Text(entry.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
            Text("\(entry.repositoryURL) · \(entry.author.isEmpty ? "Unknown author" : entry.author) · \(formatDateText(entry.updatedAt, fallback: entry.updatedAt))")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            if !entry.branch.isEmpty {
                Text("Branch: \(entry.branch.replacingOccurrences(of: "refs/heads/", with: ""))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let url = entry.validatedExternalURL {
                    ActionButton(title: "Open change", icon: "arrow.up.right.square") {
                        let identifier = entry.kind == "commit" ? String(entry.externalID.prefix(8)) : "#\(entry.externalID)"
                        model.openInlineBrowser(url: url.absoluteString, title: "\(identifier) · \(entry.title)", source: "Case development")
                    }
                }
                ActionButton(title: "Copy link", icon: "doc.on.doc") { NSPasteboard.general.setString(entry.url, forType: .string) }
                Text(entry.externalID).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var commitLinkingPanel: some View {
        NativeGroupPanel(title: "Link a commit", subtitle: "Choose a commit from a connected repository to associate with this case.") {
            if repositories.isEmpty {
                Text("Connect a repository below before linking commits.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { repositoryPicker; commitSearch }
                    VStack(alignment: .leading, spacing: 8) { repositoryPicker; commitSearch }
                }
                if let selectedRepository, !selectedRepository.canManage {
                    NativeNotice(message: "A repository administrator can link commits from this connection.")
                } else if commits.isEmpty && !isLoading {
                    Text(search.isEmpty ? "No commits available. Configure a webhook or refresh the repository history." : "No commits match this search.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(commits) { commit in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(commit.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                Text("\(commit.externalID.prefix(8)) · \(commit.author) · \(formatDateText(commit.updatedAt, fallback: commit.updatedAt))")
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            ActionButton(title: isWriting ? "Linking…" : "Link", icon: "link") { Task { await link(commit) } }
                                .disabled(isWriting || isLoading || mutationNeedsReview || selectedRepository?.canManage == false)
                        }
                        .padding(8)
                        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                if let cursor {
                    ActionButton(title: isLoading ? "Loading…" : "Load more commits", icon: "arrow.down") { Task { await loadCommits(cursor: cursor, append: true) } }
                        .disabled(isLoading || isWriting)
                }
            }
        }
    }

    private var repositoryPicker: some View {
        Picker("Repository", selection: $selectedRepositoryID) {
            ForEach(repositories) { repository in Text(repository.repositoryURL).tag(repository.id) }
        }
        .frame(maxWidth: 420)
        .onChange(of: selectedRepositoryID) { _, _ in Task { await loadCommits(cursor: nil, append: false) } }
    }

    private var commitSearch: some View {
        HStack(spacing: 6) {
            TextField("Search commits", text: $search).textFieldStyle(.roundedBorder).onSubmit { Task { await loadCommits(cursor: nil, append: false) } }
            ActionButton(title: "Search", icon: "magnifyingglass") { Task { await loadCommits(cursor: nil, append: false) } }
        }
        .frame(maxWidth: 360)
    }

    private var repositoryConnectionsPanel: some View {
        NativeGroupPanel(title: "Repository connections", subtitle: "Personal links are private. Organization links are shared with active members.") {
            if repositories.isEmpty {
                Text("No repositories connected.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
            } else {
                ForEach(repositories) { repository in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(repository.repositoryURL).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        Text("\(repository.provider.capitalized) · \(repository.lastReceivedAt.map { "Last event \(formatDateText($0, fallback: $0))" } ?? "Waiting for the first webhook event")")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                        if let warning = repository.lastWarning, !warning.isEmpty { NativeNotice(message: warning) }
                        if repository.canManage {
                            ActionButton(title: "Disconnect", icon: "minus.circle") { pendingDisconnect = repository }
                                .disabled(isLoading || isWriting || mutationNeedsReview)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9).background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if canConnectRepository {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { providerPicker; repositoryURLField; connectButton }
                    VStack(alignment: .leading, spacing: 8) { providerPicker; repositoryURLField; connectButton }
                }
            } else if activeOrganizationID != nil {
                Text("An active organization owner or admin can connect or disconnect shared repositories.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var providerPicker: some View {
        Picker("Provider", selection: $provider) {
            Text("Forgejo").tag("forgejo"); Text("GitHub").tag("github"); Text("GitLab").tag("gitlab")
        }.frame(maxWidth: 150)
    }

    private var repositoryURLField: some View {
        TextField("HTTPS repository URL", text: $repositoryURL, prompt: Text("https://git.example.com/team/repository"))
            .textFieldStyle(.roundedBorder).frame(minWidth: 180, maxWidth: 420)
    }

    private var connectButton: some View {
        ActionButton(title: isWriting ? "Connecting…" : "Connect", icon: "plus") { Task { await connect() } }
            .disabled(isWriting || isLoading || mutationNeedsReview || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var canConnectRepository: Bool {
        model.hasHanasandAuth && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty && organizationCanManage
    }

    private func webhookSecretPanel(_ value: CaseDevelopmentRepositorySetup) -> some View {
        NativeGroupPanel(title: "Webhook setup · secret shown once", subtitle: "Add this webhook to the repository. Enable push and pull or merge request events, and leave TLS verification enabled.") {
            if let webhookURL = webhookURL(path: value.webhookPath) {
                labeledReadOnly("Webhook URL", value: webhookURL.absoluteString)
            } else {
                NativeNotice(message: "The webhook URL could not be formed from the configured API address.", tone: .error)
            }
            labeledReadOnly("Secret", value: value.secret)
            HStack(spacing: 8) {
                ActionButton(title: "Copy secret", icon: "doc.on.doc") { NSPasteboard.general.setString(value.secret, forType: .string) }
                ActionButton(title: "Hide secret", icon: "eye.slash") { setup = nil }
            }
            Text("For GitLab, enter the secret as “Secret token”. For GitHub and Forgejo, use “Secret”. Save the secret before hiding this panel; the server will not show it again.")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
        }
    }

    private func labeledReadOnly(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func webhookURL(path: String) -> URL? {
        guard let base = URL(string: model.settings.apiBaseURL), let scheme = base.scheme, let host = base.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = base.port
        components.path = path
        return components.url
    }

    @MainActor private func refresh() async {
        guard !isLoading else { return }
        isLoading = true; error = ""; notice = ""
        defer { isLoading = false }
        do {
            if let organizationID = activeOrganizationID,
               (model.organizationDirectorySnapshotUserID != model.userIDForRequests || model.selectedOrganizationID != organizationID) {
                guard await model.selectOrganizationFromDeepLink(organizationID), model.selectedOrganizationID == organizationID else {
                    throw CaseDevelopmentClientError.requestFailed(403)
                }
            }
            guard let client = apiClient else { throw CaseDevelopmentClientError.signInRequired }
            let capturedSettings = model.settings
            async let page = client.load(caseID: caseID, organizationID: activeOrganizationID)
            async let connections = client.loadRepositories(organizationID: activeOrganizationID)
            let (newPage, newConnections) = try await (page, connections)
            guard capturedSettings == model.settings, caseID == selectedCaseID else { return }
            entries = newPage.items; currentPageHasMore = newPage.hasMore
            repositories = newConnections
            if !repositories.contains(where: { $0.id == selectedRepositoryID }) { selectedRepositoryID = repositories.first?.id ?? "" }
            if !repositories.isEmpty { await loadCommits(cursor: nil, append: false) }
        } catch let failure { error = failure.localizedDescription }
    }

    private var selectedCaseID: String { caseID }

    @MainActor private func refreshForReview() async {
        await refresh()
        reviewRefreshed = error.isEmpty
    }

    @MainActor private func loadMore() async {
        guard !isLoading, currentPageHasMore else { return }
        isLoading = true; error = ""
        defer { isLoading = false }
        do {
            let scope = model.settings
            guard let client = apiClient else { throw CaseDevelopmentClientError.signInRequired }
            let page = try await client.load(caseID: caseID, offset: entries.count, organizationID: activeOrganizationID)
            guard scope == model.settings else { return }
            entries += page.items; currentPageHasMore = page.hasMore
        } catch let failure { error = failure.localizedDescription }
    }

    @MainActor private func loadCommits(cursor: String?, append: Bool) async {
        guard !isLoadingCommits, let selectedRepository else { commits = []; return }
        isLoadingCommits = true; error = ""
        defer { isLoadingCommits = false }
        do {
            let scope = model.settings
            guard let client = apiClient else { throw CaseDevelopmentClientError.signInRequired }
            let page = try await client.loadCommits(repositoryID: selectedRepository.id, search: search, cursor: cursor, organizationID: activeOrganizationID)
            guard scope == model.settings else { return }
            commits = append ? commits + page.items : page.items
            self.cursor = page.nextCursor
        } catch let failure { error = failure.localizedDescription }
    }

    @MainActor private func link(_ commit: CaseDevelopmentCommit) async {
        guard !isWriting, !mutationNeedsReview, let selectedRepository, let client = apiClient else { return }
        isWriting = true; error = ""; notice = ""
        defer { isWriting = false }
        do {
            let scope = model.settings
            try await client.link(commit: commit.externalID, repositoryID: selectedRepository.id, caseID: caseID, organizationID: activeOrganizationID)
            guard scope == model.settings else { lockForReview(); return }
            notice = "Commit linked to case."
            await refresh()
        } catch let failure as CaseDevelopmentClientError {
            error = failure.localizedDescription
            if CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: failure) { lockForReview() }
        } catch { self.error = error.localizedDescription; lockForReview() }
    }

    @MainActor private func connect() async {
        guard !isWriting, !mutationNeedsReview, canConnectRepository, let client = apiClient else { return }
        isWriting = true; error = ""; notice = ""; setup = nil
        defer { isWriting = false }
        do {
            let scope = model.settings
            let receipt = try await client.connect(provider: provider, repositoryURL: repositoryURL, organizationID: activeOrganizationID)
            guard scope == model.settings else { lockForReview(); return }
            setup = receipt
            repositoryURL = ""
            await refresh()
            notice = "Repository connected. Copy the webhook secret now; it is shown only once."
        } catch let failure as CaseDevelopmentClientError {
            error = failure.localizedDescription
            if CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: failure) { lockForReview() }
        } catch { self.error = error.localizedDescription; lockForReview() }
    }

    @MainActor private func disconnect(_ repository: CaseDevelopmentRepository) async {
        guard !isWriting, !mutationNeedsReview, repository.canManage, let client = apiClient else { return }
        isWriting = true; error = ""; notice = ""
        defer { isWriting = false }
        do {
            let scope = model.settings
            try await client.disconnect(repositoryID: repository.id, organizationID: activeOrganizationID)
            guard scope == model.settings else { lockForReview(); return }
            notice = "Repository disconnected and linked case activity removed."
            if selectedRepositoryID == repository.id { selectedRepositoryID = "" }
            await refresh()
        } catch let failure as CaseDevelopmentClientError {
            error = failure.localizedDescription
            if CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: failure) { lockForReview() }
        } catch { self.error = error.localizedDescription; lockForReview() }
    }

    @MainActor private func lockForReview() {
        mutationNeedsReview = true
        reviewRefreshed = false
    }
}
