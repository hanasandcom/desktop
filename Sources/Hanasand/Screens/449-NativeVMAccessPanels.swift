import AppKit
import SwiftUI

struct NativeVMAccessPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let vm: NativeVMInventoryItem
    let canManage: Bool
    let onChanged: () -> Void

    @State private var connection: NativeVMConnection?
    @State private var connectionStatus = "Loading SSH access…"
    @State private var isLoadingConnection = false

    private var scopeKey: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.selectedOrganizationID)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(vm.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Access", subtitle: "Connect with SSH keys saved to your Hanasand profile") {
                if let connection {
                    fact("Username", connection.username)
                    fact("Host", connection.ipAddress.isEmpty ? "IP attaching" : connection.ipAddress)
                    fact("Profile SSH keys", String(connection.certificateCount))
                    if let command = connection.sshCommand {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                        HStack(spacing: 8) {
                            ActionButton(title: "Copy SSH command", icon: "doc.on.doc") { copy(command) }
                            ActionButton(title: "SSH keys", icon: "key.horizontal") { model.openNativeDashboard(path: "/profile", label: "Profile") }
                        }
                        if connectionStatus == "SSH command copied." {
                            Text(connectionStatus).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        }
                    } else {
                        Text(connection.certificateCount == 0
                             ? "Add an SSH key to your profile to enable passwordless access from your Mac."
                             : "The SSH command is not ready yet. Check again after the VM receives an IP address.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        ActionButton(title: "SSH keys", icon: "key.horizontal") { model.openNativeDashboard(path: "/profile", label: "Profile") }
                    }
                    NativeVMSudoPasswordButton(vmName: vm.name)
                } else {
                    Text(connectionStatus).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    ActionButton(title: isLoadingConnection ? "Loading…" : "Refresh access", icon: "arrow.clockwise") {
                        Task { await loadConnection() }
                    }.disabled(isLoadingConnection || !model.hasHanasandAuth)
                }
            }

            NativeVMHostOptionsPanel(vm: vm, canManage: canManage, onChanged: onChanged)
        }
        .task(id: scopeKey) { await loadConnection() }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(theme.text).textSelection(.enabled)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        connectionStatus = "SSH command copied."
    }

    @MainActor private func loadConnection() async {
        connection = nil
        guard model.hasHanasandAuth else { connectionStatus = "Sign in to load VM access details."; return }
        guard !model.isProfileIdentityImpersonating else { connectionStatus = "VM access details are unavailable while impersonating."; return }
        let capturedScope = scopeKey
        isLoadingConnection = true
        defer { if capturedScope == scopeKey { isLoadingConnection = false } }
        do {
            let client = try makeClient()
            let value = try await client.loadConnection(for: vm.name)
            guard capturedScope == scopeKey else { return }
            connection = value
            connectionStatus = ""
        } catch {
            guard capturedScope == scopeKey else { return }
            connectionStatus = error.localizedDescription
        }
    }

    private func makeClient() throws -> NativeVMAccessClient {
        try NativeVMAccessClient(
            apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
            userID: model.userIDForRequests,
            token: model.authTokenForRequests,
            organizationID: model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }
}

private struct NativeVMHostOptionsPanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let vm: NativeVMInventoryItem
    let canManage: Bool
    let onChanged: () -> Void

    @State private var pendingAction: Action?
    @State private var status = ""
    @State private var busy = false

    private enum Action: String, Identifiable {
        case enable, disable, failover
        var id: String { rawValue }
    }

    private var mayManage: Bool {
        NativeVMAccessPolicy.mayManage(canManage: canManage, isImpersonating: model.isProfileIdentityImpersonating,
                                       hasCredentials: model.hasHanasandAuth)
    }

    var body: some View {
        NativeGroupPanel(title: "Host options", subtitle: "\(vm.primaryHost ?? "ovhcloud") primary\(vm.failoverHost.map { ", \($0) standby" } ?? "")") {
            HStack(alignment: .firstTextBaseline) {
                Text("Automatic failover").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Spacer(minLength: 8)
                Text(failoverSummary).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            Text("Keep a standby copy so the host can move between OVHcloud and Inspur.")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)

            if vm.failoverPremium == true {
                ActionButton(title: vm.failoverEnabled == true ? "Disable automatic failover" : "Enable automatic failover",
                             icon: vm.failoverEnabled == true ? "pause.circle" : "arrow.left.arrow.right") {
                    pendingAction = vm.failoverEnabled == true ? .disable : .enable
                }.disabled(!mayManage || busy || vm.isScheduledForDeletion)
            } else {
                ActionButton(title: busy ? "Opening checkout…" : "Buy automatic failover", icon: "cart") {
                    Task { await buyFailover() }
                }.disabled(!mayManage || busy || vm.isScheduledForDeletion)
            }
            if vm.failoverEnabled == true, vm.failoverHost?.isEmpty == false {
                ActionButton(title: "Review failover to \(vm.failoverHost!)", icon: "arrow.left.arrow.right") {
                    pendingAction = .failover
                }.disabled(!mayManage || busy || vm.isScheduledForDeletion)
            }
            if !mayManage {
                Text(model.isProfileIdentityImpersonating
                     ? "Host options are read-only while impersonating."
                     : "Current VM owner or editor access is required to change host options.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
            if !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundStyle(status.contains("could not") || status.contains("uncertain") ? theme.danger : theme.textSecondary).textSelection(.enabled)
            }
        }
        .confirmationDialog(actionTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let pendingAction {
                Button(confirmTitle(pendingAction), role: pendingAction == .disable || pendingAction == .failover ? .destructive : nil) {
                    Task { await perform(pendingAction) }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(actionMessage)
        }
    }

    private var failoverSummary: String {
        guard let premium = vm.failoverPremium, let enabled = vm.failoverEnabled else { return "Status unavailable" }
        if !premium { return "Optional upgrade" }
        return enabled ? "On" : "Off"
    }

    private var actionTitle: String { pendingAction.map { "Review \($0.rawValue) for \(vm.name)?" } ?? "Review host option" }
    private var actionMessage: String {
        switch pendingAction {
        case .enable: "This enables the purchased standby host for \(vm.name)."
        case .disable: "This turns off automatic failover for \(vm.name)."
        case .failover: "Move \(vm.name) to \(vm.failoverHost ?? "the standby host") now. The service will report the confirmed result."
        case nil: ""
        }
    }

    private func confirmTitle(_ action: Action) -> String {
        switch action {
        case .enable: "Enable failover"
        case .disable: "Disable failover"
        case .failover: "Fail over now"
        }
    }

    @MainActor private func perform(_ action: Action) async {
        pendingAction = nil
        guard mayManage, !busy else { return }
        let scope = scopeKey
        busy = true
        defer { busy = false }
        do {
            let workspace = try makeWorkspaceClient()
            async let inventoryTask = workspace.loadInventory()
            async let managementTask = workspace.loadManagement(for: vm.name)
            let (inventory, access) = try await (inventoryTask, managementTask)
            guard scope == scopeKey else { status = "Account or organization changed. Refresh before retrying."; return }
            guard let current = inventory.items.first(where: { $0.name == vm.name }),
                  inventory.isComplete, access.canManage,
                  !current.isScheduledForDeletion else { throw NativeVMAccessError.accessDenied }

            let client = try makeAccessClient()
            switch action {
            case .enable:
                guard current.failoverPremium == true, current.failoverEnabled != true else { throw NativeVMAccessError.accessDenied }
                _ = try await client.updateFailover(for: vm.name, enabled: true)
                status = "Automatic failover enabled."
            case .disable:
                guard current.failoverPremium == true, current.failoverEnabled == true else { throw NativeVMAccessError.accessDenied }
                _ = try await client.updateFailover(for: vm.name, enabled: false)
                status = "Automatic failover disabled."
            case .failover:
                guard current.failoverPremium == true, current.failoverEnabled == true,
                      let standbyHost = current.failoverHost, !standbyHost.isEmpty else { throw NativeVMAccessError.accessDenied }
                status = try await client.runFailover(for: vm.name, targetHost: standbyHost, requestID: UUID()).message
            }
            guard scope == scopeKey else { status = "The operation completed; refresh the current workspace state."; return }
            onChanged()
        } catch {
            status = error is NativeVMAccessError && (error as? NativeVMAccessError) == .uncertainOutcome
                ? "The failover request outcome is uncertain. Refresh VM details before another action."
                : error.localizedDescription
        }
    }

    @MainActor private func buyFailover() async {
        guard mayManage, !busy, !vm.isScheduledForDeletion else { return }
        let scope = scopeKey
        busy = true
        defer { busy = false }
        do {
            let workspace = try makeWorkspaceClient()
            async let inventoryTask = workspace.loadInventory()
            async let managementTask = workspace.loadManagement(for: vm.name)
            let (inventory, access) = try await (inventoryTask, managementTask)
            guard scope == scopeKey, inventory.isComplete,
                  let current = inventory.items.first(where: { $0.name == vm.name }),
                  access.canManage, current.failoverPremium != true, !current.isScheduledForDeletion else {
                throw NativeVMAccessError.accessDenied
            }
            let checkout = try await makeAccessClient().loadFailoverCheckoutURL(for: vm.name)
            guard scope == scopeKey else { status = "Account or organization changed. Refresh before opening checkout."; return }
            let didOpen = model.openStripeInAppBrowser(url: checkout.absoluteString, title: "checkout", source: "VM failover")
            status = didOpen ? "Secure Stripe checkout opened in the built-in browser." : "Could not open secure Stripe checkout in the built-in browser."
        } catch {
            status = error.localizedDescription
        }
    }

    private var scopeKey: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.selectedOrganizationID)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(vm.name)"
    }

    private func makeWorkspaceClient() throws -> NativeVMWorkspaceClient {
        try NativeVMWorkspaceClient(apiBaseURL: model.settings.apiBaseURL, userID: model.userIDForRequests,
                                    token: model.authTokenForRequests,
                                    organizationID: model.selectedOrganizationID.isEmpty ? nil : model.selectedOrganizationID)
    }

    private func makeAccessClient() throws -> NativeVMAccessClient {
        try NativeVMAccessClient(apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                                 userID: model.userIDForRequests, token: model.authTokenForRequests,
                                 organizationID: model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID,
                                 impersonationToken: model.settings.impersonationToken,
                                 impersonatingUserID: model.settings.impersonatingUserID)
    }
}

struct NativeVMSudoPasswordButton: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    let vmName: String

    @State private var isPresented = false
    @State private var currentPassword = ""
    @State private var revealedPassword: String?
    @State private var error = ""
    @State private var isLoading = false
    @State private var copied = false
    @State private var canContactSupport = false
    @State private var unavailableErrorScopeKey = ""
    @State private var requestGeneration = 0

    private var isImpersonating: Bool { model.isProfileIdentityImpersonating }
    private var mayReveal: Bool {
        NativeVMAccessPolicy.mayRevealSudoPassword(isImpersonating: isImpersonating, hasCredentials: model.hasHanasandAuth)
    }

    var body: some View {
        ActionButton(title: "Show sudo password", icon: "key.fill") {
            clear()
            isPresented = true
        }
        .disabled(!mayReveal)
        .sheet(isPresented: $isPresented, onDismiss: clear) {
            VStack(alignment: .leading, spacing: 14) {
                Text("VM sudo password").font(.title2.weight(.semibold)).foregroundStyle(theme.text)
                Text("Enter your current Hanasand account password. Only the VM owner or an authorized platform administrator can view this password. Each reveal is recorded in the access audit and sends a security email to the VM owner. The password is shown briefly and is not saved.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let revealedPassword {
                    Text(revealedPassword)
                        .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(copied ? "Copied" : "Copy password") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(revealedPassword, forType: .string)
                            copied = true
                        }
                        Button("Hide now", role: .cancel) { isPresented = false }
                    }
                    .task(id: revealedPassword) {
                        try? await Task.sleep(for: .seconds(20))
                        if !Task.isCancelled && self.revealedPassword == revealedPassword { isPresented = false }
                    }
                } else {
                    SecureField("Current Hanasand password", text: $currentPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await reveal() } }
                    if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(theme.danger).textSelection(.enabled) }
                    if canContactSupport, unavailableErrorScopeKey == scopeKey, mayReveal,
                       let safeVMName = SupportVMUnavailableTicketPrefill.sanitizedVMName(vmName) {
                        ActionButton(title: "Contact Support", icon: "bubble.left.and.bubble.right") {
                            guard canContactSupport, unavailableErrorScopeKey == scopeKey, mayReveal else { return }
                            model.openNativeDashboard(path: "/support", label: "Support", query: [
                                "newTicket": "vm-sudo-password", "vm": safeVMName
                            ])
                            isPresented = false
                        }
                    }
                    HStack {
                        Button(isLoading ? "Verifying…" : "Verify and show") { Task { await reveal() } }
                            .disabled(isLoading || currentPassword.isEmpty || !mayReveal)
                        Button("Cancel", role: .cancel) { isPresented = false }
                    }
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    @MainActor private func reveal() async {
        guard mayReveal, !isLoading, !currentPassword.isEmpty else { return }
        let generation = requestGeneration
        let scope = scopeKey
        let password = currentPassword
        currentPassword = ""
        error = ""
        canContactSupport = false
        unavailableErrorScopeKey = ""
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try NativeVMAccessClient(apiBaseURL: model.settings.apiBaseURL.normalizedBaseURL,
                                                  userID: model.userIDForRequests, token: model.authTokenForRequests,
                                                  organizationID: model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal" ? nil : model.selectedOrganizationID,
                                                  impersonationToken: model.settings.impersonationToken,
                                                  impersonatingUserID: model.settings.impersonatingUserID)
            let value = try await client.revealSudoPassword(for: vmName, currentPassword: password)
            guard generation == requestGeneration, scope == scopeKey, isPresented, mayReveal else { return }
            revealedPassword = value
        } catch {
            guard generation == requestGeneration, scope == scopeKey, isPresented else { return }
            self.error = error.localizedDescription
            canContactSupport = (error as? NativeVMAccessError) == .sudoPasswordUnavailable
            unavailableErrorScopeKey = canContactSupport ? scope : ""
        }
    }

    private func clear() {
        requestGeneration += 1
        currentPassword = ""
        revealedPassword = nil
        error = ""
        canContactSupport = false
        unavailableErrorScopeKey = ""
        isLoading = false
        copied = false
    }

    private var scopeKey: String {
        "\(vmName)|\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests.hashValue)|\(model.selectedOrganizationID)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)"
    }
}
