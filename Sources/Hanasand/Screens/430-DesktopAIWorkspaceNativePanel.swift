import SwiftUI

struct DesktopAIWorkspaceNativePanel: View {
    let conversationID: String?
    let shareID: String?
    let shareFileID: String?
    let shareFilePath: String?
    let createShareConversation: Bool

    @EnvironmentObject private var desktopModel: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var workspace: DesktopAIWorkspaceViewModel
    @State private var search = ""
    @State private var showArchived = false
    @State private var titleDraft = ""
    @State private var composer = ""
    @State private var selectedProvider = "hanasand"
    @State private var showingDeleteConfirmation = false
    @State private var deploymentVMName = ""
    @State private var deploymentPort = "3000"
    @State private var deploymentHealthPath = "/"
    @State private var deploymentAccessPolicy = "owner_only"
    @State private var deploymentEnvironment = "staging"
    @State private var showingDeploymentConfirmation = false
    @State private var rollbackRelease: DesktopAIRelease?
    @State private var showingRollbackConfirmation = false
    @State private var showingSupportBundle = false
    @State private var inviteUserID = ""
    @State private var inviteRole = "reviewer"
    @State private var removeCollaboratorID: String?
    @State private var showingRemoveCollaboratorConfirmation = false

    init(conversationID: String? = nil, shareID: String? = nil, shareFileID: String? = nil,
         shareFilePath: String? = nil, createShareConversation: Bool = false) {
        self.conversationID = conversationID
        self.shareID = shareID
        self.shareFileID = shareFileID
        self.shareFilePath = shareFilePath
        self.createShareConversation = createShareConversation
        _workspace = StateObject(wrappedValue: DesktopAIWorkspaceViewModel())
    }

    private var visibleConversations: [DesktopAIConversation] {
        workspace.conversations.filter { showArchived || $0.archivedAt == nil }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: 210, idealWidth: 250, maxWidth: 310)
            Rectangle().fill(theme.divider).frame(width: 1)
            conversationPane
        }
        .task(id: "\(conversationID ?? "")|\(shareID ?? "")|\(shareFileID ?? "")|\(shareFilePath ?? "")|\(createShareConversation)") {
            workspace.configureRoute(conversationID: conversationID, shareID: shareID,
                                     shareFileID: shareFileID, shareFilePath: shareFilePath,
                                     createShareConversation: createShareConversation)
            await workspace.refresh(settings: desktopModel.settings)
        }
        .onChange(of: workspace.selectedConversationID) { _, _ in
            titleDraft = workspace.selectedConversation?.title ?? ""
            workspace.startChatGPTPolling()
            Task { await workspace.refreshDeploymentData() }
        }
        .alert("Delete this conversation?", isPresented: $showingDeleteConfirmation) {
            Button("Delete conversation", role: .destructive) { Task { await workspace.deleteSelected() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the saved conversation and its message history from your Hanasand AI workspace.")
        }
        .confirmationDialog("Start remote launch check?", isPresented: $showingDeploymentConfirmation, titleVisibility: .visible) {
            Button("Start \(deploymentEnvironment.capitalized) launch check") {
                Task {
                    await workspace.startDeployment(vmName: deploymentVMName, port: deploymentPort,
                        healthPath: deploymentHealthPath, accessPolicy: deploymentAccessPolicy,
                        environment: deploymentEnvironment)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This sends the attached repository to the selected VM and starts a remote launch health check on port \(deploymentPort).")
        }
        .confirmationDialog("Mark this release as the rollback target?", isPresented: $showingRollbackConfirmation, titleVisibility: .visible) {
            Button("Mark rollback target", role: .destructive) {
                if let rollbackRelease { Task { await workspace.markRollbackTarget(rollbackRelease) } }
                rollbackRelease = nil
            }
            Button("Cancel", role: .cancel) { rollbackRelease = nil }
        } message: {
            Text("This updates release history only. Restoring the running service still requires a manual runtime step.")
        }
        .confirmationDialog("AI requests permission", isPresented: Binding(
            get: { workspace.pendingToolAction != nil },
            set: { value in if !value { Task { await workspace.rejectPendingToolAction() } } }
        ), titleVisibility: .visible) {
            Button("Approve and run once") { Task { await workspace.confirmPendingToolAction() } }
            Button("Cancel", role: .cancel) { Task { await workspace.rejectPendingToolAction() } }
        } message: {
            Text(workspace.pendingToolAction?.call.confirmationSummary ?? "Review the requested action before it runs.")
        }
        .confirmationDialog("Remove this collaborator?", isPresented: $showingRemoveCollaboratorConfirmation, titleVisibility: .visible) {
            Button("Remove access", role: .destructive) {
                if let removeCollaboratorID { Task { await workspace.removeCollaborator(userID: removeCollaboratorID) } }
                removeCollaboratorID = nil
            }
            Button("Cancel", role: .cancel) { removeCollaboratorID = nil }
        } message: {
            Text("They will lose access to this shared AI conversation.")
        }
        .sheet(isPresented: $showingSupportBundle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Release support bundle").font(.headline)
                    Spacer()
                    Button("Done") { showingSupportBundle = false }
                }
                ScrollView {
                    Text(workspace.supportBundleText ?? "Loading support bundle…")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(18).frame(minWidth: 520, minHeight: 360)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI workspace").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Saved Hanasand conversations").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 4)
                Button { Task { await workspace.refresh(settings: desktopModel.settings) } } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh conversations").disabled(workspace.isLoading)
            }
            Button { Task { await workspace.createConversation() } } label: {
                Label("New chat", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderedProminent)
            TextField("Search chats", text: $search).textFieldStyle(.roundedBorder)
            Toggle("Show archived", isOn: $showArchived).font(.system(size: 11, weight: .medium))
                .toggleStyle(.checkbox)

            if workspace.isLoading && workspace.conversations.isEmpty {
                NativeEmptyState(title: "Loading chats", message: "Retrieving saved Hanasand AI conversations.")
            } else if visibleConversations.isEmpty {
                NativeEmptyState(title: showArchived ? "No archived chats" : "No conversations", message: search.isEmpty ? "Create a conversation to start a persistent AI chat." : "No conversations match this search.")
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(visibleConversations) { conversation in
                            Button { workspace.select(conversation.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(conversation.title).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 2)
                                        if conversation.archivedAt != nil { Image(systemName: "archivebox").font(.system(size: 9)) }
                                    }
                                    Text("\(conversation.messages.count) messages · \(date(conversation.updatedAt))")
                                        .font(.system(size: 9)).foregroundStyle(theme.textTertiary).lineLimit(1)
                                }
                                .font(.system(size: 11, weight: conversation.id == workspace.selectedConversationID ? .semibold : .medium))
                                .foregroundStyle(conversation.id == workspace.selectedConversationID ? theme.text : theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(conversation.id == workspace.selectedConversationID ? theme.cardRaised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !workspace.repositories.isEmpty {
                NativeGroupPanel(title: "Attached repositories", subtitle: "\(workspace.repositories.count) repositories in this account") {
                    ForEach(workspace.repositories) { repository in
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            VStack(alignment: .leading) {
                                Text(repository.fullName).font(.system(size: 10, weight: .semibold))
                                Text("\(repository.branch) · \(repository.syncStatus)").font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }.foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder private var conversationPane: some View {
        if workspace.isLoading && workspace.conversations.isEmpty {
            NativeEmptyState(title: "Loading AI workspace", message: "Retrieving conversations and attached repositories.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.routeConversationMissing {
            NativeEmptyState(title: "Conversation unavailable", message: "The conversation in this route was not found or is not available to this account.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let conversation = workspace.selectedConversation {
            conversationDetail(conversation)
        } else if let error = workspace.errorMessage {
            VStack(spacing: 12) {
                NativeEmptyState(title: "AI workspace unavailable", message: error)
                Button("Try again") { Task { await workspace.refresh(settings: desktopModel.settings) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NativeEmptyState(title: "Select a conversation", message: "Choose a saved chat or create a new one.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func conversationDetail(_ conversation: DesktopAIConversation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Conversation title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await workspace.renameSelected(titleDraft) } }
                    .disabled(!conversation.canWrite)
                Button("Save title") { Task { await workspace.renameSelected(titleDraft) } }
                    .disabled(!conversation.canWrite || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu {
                    Button(conversation.archivedAt == nil ? "Archive conversation" : "Restore conversation", systemImage: conversation.archivedAt == nil ? "archivebox" : "tray.and.arrow.up") {
                        Task { await workspace.setArchived(conversation.archivedAt == nil) }
                    }.disabled(!conversation.canWrite)
                    Divider()
                    Button("Delete conversation…", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
                        .disabled(!conversation.canWrite)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
                Button { Task { await workspace.refresh(settings: desktopModel.settings) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh workspace")
            }
            .padding(12)
            HStack(spacing: 10) {
                Picker("Strategy", selection: Binding(
                    get: { conversation.modelStrategy },
                    set: { value in Task { await workspace.setModelStrategy(value) } }
                )) {
                    Text("Automatic").tag("auto")
                    Text("Pinned").tag("pinned")
                }
                .pickerStyle(.menu)
                .disabled(!conversation.canWrite)
                Picker("Model", selection: Binding(
                    get: { conversation.preferredModel ?? "" },
                    set: { value in Task { await workspace.setPreferredModel(value.isEmpty ? nil : value) } }
                )) {
                    Text("Automatic model").tag("")
                    if let preferredModel = conversation.preferredModel, !workspace.availableModelNames.contains(preferredModel) {
                        Text("Unavailable: \(preferredModel)").tag(preferredModel)
                    }
                    ForEach(workspace.availableModelNames, id: \.self) { name in Text(name).tag(name) }
                }
                .pickerStyle(.menu)
                .disabled(!conversation.canWrite || workspace.availableModelNames.isEmpty)
                if workspace.availableModelNames.isEmpty {
                    Text("No connected models · text endpoint").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
                Menu {
                    if workspace.repositories.isEmpty && workspace.shares.isEmpty {
                        Text("No repositories or shares available")
                    }
                    if !workspace.repositories.isEmpty {
                        Section("Repositories") {
                            ForEach(workspace.repositories) { repository in
                                Button("\(repository.fullName) · \(repository.branch)") {
                                    Task { await workspace.attachRepository(repository) }
                                }
                            }
                        }
                    }
                    if !workspace.shares.isEmpty {
                        Section("Shares") {
                            ForEach(workspace.shares) { share in
                                Button(share.locked == true ? "\(share.displayName) · Read-only" : share.displayName) {
                                    Task { await workspace.attachShare(share) }
                                }
                            }
                        }
                    }
                } label: { Label("Attach context", systemImage: "paperclip") }
                .disabled(!conversation.canWrite)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            if let shareError = workspace.shareErrorMessage {
                NativeNotice(message: "Could not load shares: \(shareError)")
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let workspaceKind = conversation.workspaceKind, let workspaceID = conversation.workspaceId {
                HStack(spacing: 6) {
                    Image(systemName: workspaceKind == "repo" ? "chevron.left.forwardslash.chevron.right" : "folder")
                    Text(workspaceKind == "repo" ? "Repository context · \(workspaceID)" : "Share context · \(workspaceID)")
                    Spacer()
                }
                .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            collaborationSection(conversation)
            deploymentSection(conversation)
            Divider()
            if let error = workspace.errorMessage { NativeNotice(message: error).padding(.horizontal, 12).padding(.top, 8) }
            if let notice = workspace.toolActionNotice { NativeNotice(message: notice).padding(.horizontal, 12).padding(.top, 8) }
            if !conversation.canWrite {
                NativeNotice(message: "You have reviewer access. This conversation is read-only.").padding(.horizontal, 12).padding(.top, 8)
            }
            if conversation.messages.isEmpty && workspace.chatGPTItems.isEmpty {
                NativeEmptyState(title: "Start the conversation", message: "Messages and replies will be saved to this Hanasand AI conversation.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(displayedMessages(for: conversation)) { message in
                            messageCard(message)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Picker("AI provider", selection: $selectedProvider) {
                    Text("Hanasand AI").tag("hanasand")
                    Text("ChatGPT").tag("chatgpt")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .disabled(!conversation.canWrite || workspace.isSending || workspace.isSubmittingChatGPT)
                Spacer(minLength: 0)
                if selectedProvider == "chatgpt" {
                    Button {
                        Task { await workspace.refreshChatGPTActivity(clearUncertain: true) }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh ChatGPT queue")
                    .disabled(workspace.isRefreshingChatGPTActivity || !workspace.canUseChatGPT)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            if selectedProvider == "chatgpt" {
                if !conversation.canWrite {
                    NativeNotice(message: "Reviewer access is read-only. ChatGPT requests are unavailable.")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if workspace.chatGPTMembership == .loading {
                    NativeNotice(message: "Verifying Hanasand organization membership…")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if case .error(let message) = workspace.chatGPTMembership {
                    NativeNotice(message: "ChatGPT access could not be verified: \(message). Refresh the workspace to retry.")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if !workspace.canUseChatGPT {
                    NativeNotice(message: "ChatGPT is available to active Hanasand organization members.")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if !workspace.chatGPTHistoryReady {
                    NativeNotice(message: workspace.isRefreshingChatGPTActivity ? "Loading complete ChatGPT conversation history…" : "Loading complete ChatGPT conversation history before sending…")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if workspace.chatGPTSubmissionUncertain {
                    NativeNotice(message: "\(workspace.chatGPTActivityError ?? "The request outcome is unknown.")")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if let error = workspace.chatGPTActivityError {
                    NativeNotice(message: "ChatGPT queue refresh failed: \(error)")
                        .padding(.horizontal, 12).padding(.top, 6)
                } else if let summary = workspace.chatGPTStatusSummary {
                    Text(summary).font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 5)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(selectedProvider == "chatgpt" ? "Ask ChatGPT" : "Ask Hanasand AI", text: $composer, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5)
                    .onSubmit { submit() }
                    .disabled(!conversation.canWrite || workspace.isSending || workspace.isSubmittingChatGPT
                        || (selectedProvider == "chatgpt" && (!workspace.canUseChatGPT || !workspace.chatGPTHistoryReady || workspace.chatGPTSubmissionUncertain)))
                Button { submit() } label: {
                    Label(isProviderWorking ? "Working" : "Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!conversation.canWrite || isProviderWorking || composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (selectedProvider == "chatgpt" && (!workspace.canUseChatGPT || !workspace.chatGPTHistoryReady || workspace.chatGPTSubmissionUncertain)))
            }
            .padding(12)
            Text(selectedProvider == "chatgpt" ? "ChatGPT requests are added to the shared queue and update here automatically." : "Chats are saved in your account. Connected models are used when available; otherwise replies use the Hanasand AI text endpoint.")
                .font(.system(size: 9)).foregroundStyle(theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12)
        }
    }

    private func deploymentSection(_ conversation: DesktopAIConversation) -> some View {
        DisclosureGroup("Deployments & releases") {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if let quota = workspace.deployQuota {
                            Text("Launch checks: \(quota.used)/\(quota.limit) · previews: \(quota.activeRunning)/\(quota.maxRunning)")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                            Text("Resets \(date(quota.resetsAt))").font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                        } else {
                            Text("Quota details unavailable").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Button { Task { await workspace.refreshDeploymentData() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }.help("Refresh deployment status").disabled(workspace.isRefreshingDeployment)
                    }
                    if !conversation.canWrite {
                        NativeNotice(message: "Reviewer access is read-only. Launch checks and release changes are unavailable.")
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                            GridRow {
                                Picker("VM target", selection: $deploymentVMName) {
                                    Text("Choose target").tag("")
                                    ForEach(workspace.deploymentTargets) { target in Text(target.name).tag(target.name) }
                                }
                                .frame(minWidth: 190)
                                TextField("Port", text: $deploymentPort).frame(width: 70)
                                TextField("Health path", text: $deploymentHealthPath).frame(minWidth: 100)
                            }
                            GridRow {
                                Picker("Environment", selection: $deploymentEnvironment) {
                                    Text("Staging").tag("staging")
                                    Text("Production").tag("production")
                                }
                                Picker("Preview access", selection: $deploymentAccessPolicy) {
                                    Text("Owner only").tag("owner_only")
                                    Text("Collaborators").tag("collaborators")
                                    Text("Public preview").tag("public_preview")
                                }
                                Button(workspace.isStartingDeployment ? "Starting…" : "Start launch check") {
                                    showingDeploymentConfirmation = true
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(workspace.isStartingDeployment || deploymentVMName.isEmpty || workspace.deploymentTargets.isEmpty)
                            }
                        }
                        .font(.system(size: 10))
                        if workspace.deploymentTargets.isEmpty {
                            Text("No launch targets are available to this account.").font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    if let notice = workspace.deploymentNotice { NativeNotice(message: notice) }
                    if workspace.deployments.isEmpty {
                        Text("No launch checks for this conversation.").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    } else {
                        ForEach(workspace.deployments) { deployment in
                            NativeGroupPanel(title: "\(deployment.serviceName.isEmpty ? deployment.vmName : deployment.serviceName) · \(deployment.status.capitalized)", subtitle: "\(deployment.vmName) · \(deployment.stackType) · \(date(deployment.updatedAt))") {
                                HStack(spacing: 8) {
                                    if let url = deployment.previewUrl, URL(string: url)?.scheme == "https" {
                                        Text("Preview: \(url)").font(.system(size: 9)).textSelection(.enabled)
                                    }
                                    if let url = deployment.healthcheckUrl, URL(string: url)?.scheme == "https" {
                                        Text("Health: \(url)").font(.system(size: 9)).textSelection(.enabled)
                                    }
                                }
                                if let failure = deployment.failureReason, !failure.isEmpty {
                                    Text(failure).font(.system(size: 9)).foregroundStyle(theme.danger).textSelection(.enabled)
                                }
                                ForEach(deployment.events.suffix(4)) { event in
                                    Text("\(event.stage): \(event.message)").font(.system(size: 9)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !workspace.releases.isEmpty {
                        Text("Release history").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                        ForEach(workspace.releases) { release in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(release.vmName) · \(release.status.replacingOccurrences(of: "_", with: " ").capitalized)")
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text)
                                    Text("\(release.stackType) · \(date(release.updatedAt))")
                                        .font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                                    if let url = release.previewUrl, URL(string: url)?.scheme == "https" {
                                        Text(url).font(.system(size: 9)).textSelection(.enabled)
                                    }
                                    if let notes = release.notes, !notes.isEmpty {
                                        Text(notes).font(.system(size: 9)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button("Support bundle") {
                                    workspace.clearSupportBundle()
                                    Task {
                                        await workspace.loadSupportBundle(for: release)
                                        if workspace.supportBundleText != nil { showingSupportBundle = true }
                                    }
                                }.disabled(workspace.rollbackPendingID != nil)
                                if release.ownerId == workspace.currentOwnerID && release.status != "current" && release.status != "rollback_target" {
                                    Button("Rollback target") { rollbackRelease = release; showingRollbackConfirmation = true }
                                        .disabled(workspace.rollbackPendingID != nil)
                                }
                            }
                            .padding(8).background(theme.card, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 190)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
    }

    private func collaborationSection(_ conversation: DesktopAIConversation) -> some View {
        DisclosureGroup("People & access") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shared as \(conversation.collaboration.role) · \(conversation.collaboration.seatCount)/\(conversation.collaboration.seatLimit) seats")
                    .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                if conversation.collaboration.canInvite {
                    HStack {
                        TextField("Hanasand user ID", text: $inviteUserID).textFieldStyle(.roundedBorder)
                        Picker("Role", selection: $inviteRole) {
                            Text("Reviewer").tag("reviewer")
                            Text("Editor").tag("editor")
                        }.frame(width: 110)
                        Button(workspace.isUpdatingCollaborators ? "Saving…" : "Invite") {
                            Task {
                                await workspace.inviteCollaborator(userID: inviteUserID, role: inviteRole)
                                if workspace.collaborationErrorMessage == nil { inviteUserID = "" }
                            }
                        }.disabled(workspace.isUpdatingCollaborators || inviteUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation.collaboration.remainingSeats <= 0)
                    }
                }
                if conversation.collaboration.collaborators.isEmpty {
                    Text("No collaborators yet.").font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(conversation.collaboration.collaborators) { collaborator in
                        HStack(spacing: 7) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collaborator.displayName)
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.text)
                                Text("\(collaborator.userId) · \(collaborator.role)")
                                    .font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            if conversation.collaboration.canInvite || collaborator.userId == workspace.currentOwnerID {
                                Button(role: .destructive) {
                                    removeCollaboratorID = collaborator.userId
                                    showingRemoveCollaboratorConfirmation = true
                                } label: { Image(systemName: "person.badge.minus") }
                                    .help("Remove collaborator").disabled(workspace.isUpdatingCollaborators)
                            }
                        }
                    }
                }
                if let error = workspace.collaborationErrorMessage { NativeNotice(message: error) }
            }
            .padding(.vertical, 6)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
    }

    private func messageCard(_ message: DesktopAIMessage) -> some View {
        NativeGroupPanel(title: message.role.capitalized, subtitle: message.modelName ?? date(message.createdAt)) {
            if message.pending { ProgressView("Waiting for response…").controlSize(.small) }
            Text(message.content.isEmpty && message.pending ? "" : message.content)
                .font(.system(size: 12)).foregroundStyle(message.error ? theme.danger : theme.textSecondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if message.error { Label("This message could not be completed.", systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(theme.danger) }
            ForEach(artifacts(for: message)) { artifact in
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text)
                    if let url = artifact.url { Text(url).font(.system(size: 9)).textSelection(.enabled).foregroundStyle(theme.accent) }
                    if let path = artifact.path { Text(path).font(.system(size: 9)).textSelection(.enabled).foregroundStyle(theme.textTertiary) }
                    if let content = artifact.content, !content.isEmpty {
                        Text(content).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).lineLimit(8)
                    }
                }.padding(8).background(theme.card, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func artifacts(for message: DesktopAIMessage) -> [DesktopAIWorkspaceToolArtifact] {
        guard case .array(let items)? = message.metadata["artifacts"] else { return [] }
        return items.compactMap { item in
            guard case .object(let values) = item,
                  case .string(let kind)? = values["kind"], case .string(let title)? = values["title"] else { return nil }
            func string(_ key: String) -> String? {
                if case .string(let value)? = values[key] { return value }
                return nil
            }
            return DesktopAIWorkspaceToolArtifact(kind: kind, title: title, path: string("path"), url: string("url"), content: string("content"))
        }
    }

    private func submit() {
        let text = composer
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composer = ""
        Task {
            let sent = selectedProvider == "chatgpt"
                ? await workspace.sendChatGPTPrompt(text)
                : await workspace.sendPrompt(text)
            if !sent { composer = text }
        }
    }

    private var isProviderWorking: Bool { workspace.isSending || workspace.isSubmittingChatGPT }

    private func displayedMessages(for conversation: DesktopAIConversation) -> [DesktopAIMessage] {
        guard workspace.chatGPTActivityConversationID == conversation.id else { return conversation.messages }
        let portal = workspace.chatGPTItems.flatMap { item -> [DesktopAIMessage] in
            let pending = item.status == "queued" || item.status == "running"
            let label: String
            switch item.status {
            case "queued": label = item.priority == "now" ? "Up next" : "In the queue"
            case "running": label = "ChatGPT is working"
            case "error": label = "Could not complete"
            default: label = "Finished"
            }
            let metadata: [String: DesktopAIJSONValue] = [
                "promptPortalId": .string(item.id), "promptPortalStatus": .string(item.status),
                "statusText": .string(label),
                "files": .array(item.files.map { .object(["id": .string($0.id), "name": $0.name.map(DesktopAIJSONValue.string) ?? .null]) }),
            ]
            let reply = pending ? "\(label)…" : (item.result?.isEmpty == false ? item.result! : item.status == "error" ? "The request could not be completed." : "Completed without a text response.")
            return [
                DesktopAIMessage(id: "\(item.id)-request", role: "user", content: item.prompt, modelName: "ChatGPT", metadata: metadata, createdAt: item.createdAt),
                DesktopAIMessage(id: "\(item.id)-response", role: "assistant", content: reply, pending: pending, error: item.status == "error", modelName: "ChatGPT", metadata: metadata, createdAt: item.completedAt ?? item.startedAt ?? item.createdAt),
            ]
        }
        return (conversation.messages + portal).sorted { $0.createdAt < $1.createdAt }
    }

    private func date(_ value: String) -> String {
        guard !value.isEmpty else { return "unknown date" }
        return formatDateText(value, fallback: value)
    }
}
