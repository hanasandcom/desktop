import SwiftUI

struct VMPlatformAdministrationControls: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme

    @State private var authorization: NativeVMPlatformAdminAuthorization?
    @State private var status = ""
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var pendingStopAll = false

    private var scopeKey: String {
        [model.settings.apiBaseURL, model.userIDForRequests, model.authTokenForRequests.hashValue.description,
         model.selectedOrganizationID].joined(separator: "|")
    }

    var body: some View {
        NativeGroupPanel(title: "Platform administration", subtitle: "Global actions are not limited by inventory filters.") {
            if model.isProfileIdentityImpersonating {
                Text("Return to your own account before managing virtual machines.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
            } else if !model.hasHanasandAuth {
                Text("Sign in to review platform-wide VM actions.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
            } else if isLoading && authorization == nil {
                ProgressView("Checking platform permissions…")
            } else if authorization?.access.allowed == true, authorization?.access.canEdit == true {
                ActionButton(title: isMutating ? "Scheduling shutdowns…" : "Review stop all VMs", icon: "stop.circle", tone: .danger) {
                    pendingStopAll = true
                }.disabled(isMutating || isLoading)
            } else {
                Text(status.isEmpty ? "Platform-wide VM actions require current platform edit access." : status)
                    .font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                ActionButton(title: isLoading ? "Refreshing permissions…" : "Refresh platform permissions", icon: "arrow.clockwise") {
                    Task { await refreshAuthorization() }
                }.disabled(isLoading || isMutating)
            }
            if !status.isEmpty, authorization?.access.canEdit == true {
                Text(status).font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
        }
        .confirmationDialog("Stop all virtual machines?", isPresented: $pendingStopAll, titleVisibility: .visible) {
            Button("Stop all VMs", role: .destructive) { Task { await stopAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This queues shutdowns for every VM on the platform. Inventory filters and the selected organization do not limit this action.")
        }
        .task(id: scopeKey) { await refreshAuthorization() }
        .onChange(of: model.selectedOrganizationID) { _, _ in
            authorization = nil
            status = ""
            pendingStopAll = false
        }
    }

    private func makeClient() throws -> NativeVMAdminClient {
        try NativeVMAdminClient(
            apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }

    @MainActor private func refreshAuthorization() async {
        authorization = nil
        guard model.hasHanasandAuth, !model.isProfileIdentityImpersonating else { return }
        let capturedScope = scopeKey
        let userID = model.userIDForRequests
        let token = model.authTokenForRequests
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await makeClient().loadPlatformAuthorization()
            guard capturedScope == scopeKey, userID == model.userIDForRequests, token == model.authTokenForRequests,
                  !model.isProfileIdentityImpersonating else { return }
            authorization = fresh
            status = ""
        } catch {
            guard capturedScope == scopeKey else { return }
            status = error.localizedDescription
        }
    }

    @MainActor private func stopAll() async {
        pendingStopAll = false
        guard !isMutating, model.hasHanasandAuth, !model.isProfileIdentityImpersonating,
              authorization?.access.allowed == true, authorization?.access.canEdit == true else { return }
        let capturedScope = scopeKey
        let userID = model.userIDForRequests
        let token = model.authTokenForRequests
        isMutating = true
        defer { isMutating = false }
        do {
            let client = try makeClient()
            let fresh = try await client.loadPlatformAuthorization()
            guard capturedScope == scopeKey, userID == model.userIDForRequests, token == model.authTokenForRequests,
                  !model.isProfileIdentityImpersonating else {
                authorization = nil
                status = "Account or organization changed. Refresh platform permissions before retrying."
                return
            }
            let receipt = try await client.stopAll(fresh)
            guard capturedScope == scopeKey else {
                authorization = nil
                status = "Shutdowns were queued, but the workspace changed. Refresh the current state."
                return
            }
            status = "\(receipt.message) \(receipt.vmNames.count) VM(s) included."
            let refreshed = try? await client.loadPlatformAuthorization()
            guard capturedScope == scopeKey else {
                authorization = nil
                return
            }
            authorization = refreshed
        } catch {
            status = error.localizedDescription
            authorization = nil
        }
    }
}

struct VMAdministrationControls: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme

    let vm: NativeVMInventoryItem
    let onChanged: () -> Void

    @State private var authorization: NativeVMAdminAuthorization?
    @State private var organizations: [DashboardDirectoryOrganization] = []
    @State private var selectedOrganizationID = ""
    @State private var deletionConfirmation = ""
    @State private var pendingConfirmation: NativeVMAdminConfirmation?
    @State private var status = ""
    @State private var isLoading = false
    @State private var isMutating = false

    private var scopeKey: String {
        [model.settings.apiBaseURL, model.userIDForRequests, model.authTokenForRequests.hashValue.description,
         model.selectedOrganizationID, vm.name].joined(separator: "|")
    }

    private var availableActions: Set<NativeVMAdminScreenAction> {
        nativeVMAdminScreenActions(
            authorization: authorization,
            userID: model.userIDForRequests,
            organizationID: model.selectedOrganizationID,
            isAuthenticated: model.hasHanasandAuth,
            isImpersonating: model.isProfileIdentityImpersonating
        )
    }

    private var activeOrganizations: [DashboardDirectoryOrganization] {
        let memberships = Set(model.organizationMemberships.filter { $0.status == "active" }.map(\.id))
        guard model.organizationDirectorySnapshotUserID == model.userIDForRequests,
              !model.isProfileIdentityImpersonating else { return [] }
        return organizations.filter { $0.status == "active" && memberships.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NativeGroupPanel(title: "VM administration", subtitle: "Fresh permission checks apply before each change.") {
            if model.isProfileIdentityImpersonating {
                Text("Return to your own account before managing virtual machines.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
            } else if !model.hasHanasandAuth {
                Text("Sign in to manage virtual machines.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
            } else if isLoading {
                ProgressView("Checking VM permissions…")
            } else if authorization == nil {
                Text(status.isEmpty ? "Refresh to check VM permissions." : status)
                    .font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                ActionButton(title: "Refresh permissions", icon: "arrow.clockwise") {
                    Task { await refreshAuthorization() }
                }.disabled(isMutating)
            } else {
                if availableActions.isEmpty {
                    Text("This account cannot manage this VM in the selected workspace.")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                } else {
                    if availableActions.contains(.assignOrganization) {
                        organizationAssignment
                    }
                    if availableActions.contains(.scheduleDeletion) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Type the exact VM name to schedule deletion. The service may retain it during its recovery window.")
                                .font(.caption).foregroundStyle(theme.textSecondary)
                            TextField("Type \(vm.name)", text: $deletionConfirmation)
                                .textFieldStyle(.roundedBorder)
                            ActionButton(title: "Review deletion", icon: "trash", tone: .danger) {
                                pendingConfirmation = .delete
                            }.disabled(isMutating || deletionConfirmation != vm.name)
                        }
                    }
                    if availableActions.contains(.restore) {
                        ActionButton(title: "Restore deleted VM", icon: "arrow.uturn.backward") {
                            pendingConfirmation = .restore
                        }.disabled(isMutating)
                    }
                    if availableActions.contains(.stopAll) {
                        ActionButton(title: "Review stop all VMs", icon: "stop.circle", tone: .danger) {
                            pendingConfirmation = .stopAll
                        }.disabled(isMutating)
                    }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                }
                if isMutating { ProgressView("Updating virtual machines…") }
            }
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "Review VM administration action",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingConfirmation {
                Button(pendingConfirmation.buttonTitle, role: pendingConfirmation == .delete || pendingConfirmation == .stopAll ? .destructive : nil) {
                    Task { await perform(pendingConfirmation) }
                }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
        .task(id: scopeKey) { await refreshAuthorization() }
        .onChange(of: model.selectedOrganizationID) { _, _ in
            authorization = nil
            organizations = []
            selectedOrganizationID = ""
            deletionConfirmation = ""
            pendingConfirmation = nil
            status = ""
        }
    }

    @ViewBuilder private var organizationAssignment: some View {
        VStack(alignment: .leading, spacing: 8) {
            if activeOrganizations.isEmpty {
                Text("Load your active organization memberships before assigning this VM.")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                ActionButton(title: isLoading ? "Loading organizations…" : "Load organizations", icon: "building.2") {
                    Task { await loadOrganizations() }
                }.disabled(isLoading || isMutating)
            } else {
                Picker("Assign to organization", selection: $selectedOrganizationID) {
                    Text("Choose an organization").tag("")
                    ForEach(activeOrganizations) { organization in
                        Text(organization.name).tag(organization.id)
                    }
                }.frame(maxWidth: 360, alignment: .leading)
                ActionButton(title: "Assign organization", icon: "building.2") {
                    Task { await assignOrganization() }
                }.disabled(isMutating || selectedOrganizationID.isEmpty)
            }
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .delete: "The exact VM name was entered. This schedules deletion; it does not immediately erase the VM."
        case .restore: "Restore this VM only if the service confirms it is currently deleted."
        case .stopAll: "This schedules shutdown for every VM in the platform. Inventory filters do not limit this action."
        case nil: ""
        }
    }

    private func makeClient() throws -> NativeVMAdminClient {
        try NativeVMAdminClient(
            apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }

    @MainActor private func refreshAuthorization() async {
        authorization = nil
        guard model.hasHanasandAuth, !model.isProfileIdentityImpersonating else { return }
        let capturedScope = scopeKey
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await makeClient().loadAuthorization(for: vm.name)
            guard capturedScope == scopeKey, !model.isProfileIdentityImpersonating else { return }
            authorization = fresh
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor private func loadOrganizations() async {
        guard model.hasHanasandAuth, !model.isProfileIdentityImpersonating else { return }
        isLoading = true
        defer { isLoading = false }
        let userID = model.userIDForRequests
        let token = model.authTokenForRequests
        do {
            let snapshot = try await OrganizationDirectoryClient(settings: model.settings).loadSnapshot()
            guard userID == model.userIDForRequests, token == model.authTokenForRequests,
                  !model.isProfileIdentityImpersonating else { return }
            model.organizationDirectory = snapshot.organizations
            model.organizationMemberships = snapshot.memberships
            model.organizationDirectorySnapshotUserID = userID
            organizations = snapshot.organizations
            selectedOrganizationID = activeOrganizations.first?.id ?? ""
            status = activeOrganizations.isEmpty ? "No active organization memberships were found." : ""
        } catch {
            status = "Organization memberships could not be loaded: \(error.localizedDescription)"
        }
    }

    @MainActor private func assignOrganization() async {
        guard availableActions.contains(.assignOrganization), !selectedOrganizationID.isEmpty else { return }
        await mutate { client, fresh in
            let receipt = try await client.assignOrganization(fresh, organizationID: selectedOrganizationID)
            return "Assigned to \(receipt.name)."
        }
    }

    @MainActor private func perform(_ action: NativeVMAdminConfirmation) async {
        pendingConfirmation = nil
        switch action {
        case .delete:
            guard deletionConfirmation == vm.name, availableActions.contains(.scheduleDeletion) else { return }
            await mutate { client, fresh in
                let receipt = try await client.scheduleDeletion(fresh, confirmation: self.deletionConfirmation)
                return receipt.message
            }
        case .restore:
            guard availableActions.contains(.restore) else { return }
            await mutate { client, fresh in try await client.restore(fresh).message }
        case .stopAll:
            guard availableActions.contains(.stopAll) else { return }
            await mutate { client, fresh in
                let receipt = try await client.stopAll(fresh)
                return "\(receipt.message) \(receipt.vmNames.count) VM(s) included."
            }
        }
    }

    @MainActor private func mutate(_ operation: (NativeVMAdminClient, NativeVMAdminAuthorization) async throws -> String) async {
        guard !isMutating, model.hasHanasandAuth, !model.isProfileIdentityImpersonating else { return }
        let capturedScope = scopeKey
        isMutating = true
        defer { isMutating = false }
        do {
            let client = try makeClient()
            let fresh = try await client.loadAuthorization(for: vm.name)
            guard capturedScope == scopeKey, !model.isProfileIdentityImpersonating else {
                status = "Account or organization changed. Review the current VM before retrying."
                authorization = nil
                return
            }
            let message = try await operation(client, fresh)
            guard capturedScope == scopeKey else {
                status = "The operation completed, but the workspace changed. Refresh before continuing."
                authorization = nil
                return
            }
            status = message
            deletionConfirmation = ""
            authorization = try? await client.loadAuthorization(for: vm.name)
            onChanged()
        } catch {
            status = error.localizedDescription
            authorization = nil
            // An uncertain write is shown as uncertain. Refreshing current state is the only safe next action.
        }
    }
}
