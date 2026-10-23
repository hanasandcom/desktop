import AppKit
import SwiftUI

private enum OrganizationApiKeyPendingAction: Identifiable {
    case create(String)
    case revoke(OrganizationApiKey)

    var id: String {
        switch self {
        case let .create(name): return "create:\(name)"
        case let .revoke(key): return "revoke:\(key.id)"
        }
    }
}

struct OrganizationApiKeysNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var keys: [OrganizationApiKey] = []
    @State private var nameDraft = ""
    @State private var oneTimeSecret: String?
    @State private var pendingAction: OrganizationApiKeyPendingAction?
    @State private var busy = false
    @State private var loading = false
    @State private var error = ""
    @State private var notice = ""
    @State private var needsReview = false

    private var organizationID: String { model.selectedOrganizationID }
    private var membership: DashboardOrganizationMembership? {
        model.organizationMemberships.first { $0.id == organizationID }
    }
    private var organization: DashboardDirectoryOrganization? {
        model.organizationDirectory.first { $0.id == organizationID }
    }
    private var isImpersonating: Bool { model.isImpersonatingForOrganizationSwitch }
    private var membershipVerified: Bool {
        !organizationID.isEmpty
            && model.organizationDirectorySnapshotUserID == model.userIDForRequests
            && model.settings.selectedOrganizationUserID == model.userIDForRequests
            && membership?.status == "active"
    }
    private var mayManage: Bool {
        membershipVerified
            && OrganizationApiKeyPermission.canManage(
                role: membership?.role ?? "",
                isOwnAccount: model.organizationDirectorySnapshotUserID == model.userIDForRequests,
                isImpersonating: isImpersonating
            )
    }
    private var scopeFingerprint: String {
        "\(model.userIDForRequests)|\(model.authTokenForRequests)|\(model.selectedOrganizationID)|\(model.settings.impersonationToken)|\(model.settings.impersonatingUserID)"
    }

    var body: some View {
        FeatureWorkspace(title: "Organization API keys", subtitle: "Create and revoke organization-scoped API access") {
            if organizationID.isEmpty {
                NativeEmptyState(title: "Select an organization", message: "API keys belong to a selected organization. Choose an active organization in the directory first.")
                ActionButton(title: "Open organization directory", icon: "building.2") {
                    model.openNativeDashboard(path: "/organizations", label: "Organizations")
                }
            } else if isImpersonating {
                NativeEmptyState(title: "Return to your own account", message: "Organization API keys are unavailable while impersonating another account.")
            } else if !membershipVerified {
                NativeGroupPanel(title: "Verify organization access", subtitle: "Refresh the organization directory and active membership before managing API keys.") {
                    if let error = model.organizationDirectoryError {
                        Text(error).foregroundStyle(theme.danger)
                    }
                    ActionButton(title: "Refresh organizations", icon: "arrow.clockwise") {
                        Task { await model.loadOrganizationDirectory() }
                    }
                }
            } else if !mayManage {
                NativeEmptyState(title: "Owner or admin access required", message: "Only organization owners and administrators can view and manage API keys.")
            } else {
                keyManagement
            }
        }
        .task(id: scopeFingerprint) {
            keys = []
            oneTimeSecret = nil
            error = ""
            notice = ""
            needsReview = false
            guard mayManage else { return }
            await refresh()
        }
        .onChange(of: model.organizationDirectorySnapshotUserID) { _, _ in
            oneTimeSecret = nil
            keys = []
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { oneTimeSecret = nil }
        }
        .onDisappear { oneTimeSecret = nil }
        .confirmationDialog(dialogTitle, isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible) {
            Button(dialogButtonTitle, role: pendingActionIsRevoke ? .destructive : nil) {
                guard let action = pendingAction else { return }
                pendingAction = nil
                Task { await perform(action) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(dialogMessage)
        }
    }

    private var keyManagement: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: organization?.name ?? "Selected organization", subtitle: "API keys receive the server-defined organization public API scope and expire after 90 days.") {
                HStack(spacing: 10) {
                    TextField("New key name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy || needsReview || oneTimeSecret != nil)
                    ActionButton(title: busy ? "Working…" : "Create key", icon: "key.horizontal") {
                        pendingAction = .create(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(busy || needsReview || oneTimeSecret != nil || organization?.status != "active" || !(2...80).contains(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).count))
                    ActionButton(title: loading ? "Loading…" : "Refresh", icon: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .disabled(busy || loading)
                }
                if needsReview {
                    NativeNotice(message: "The previous create request may have succeeded. Refresh the list before creating another key.", tone: .info)
                }
                if organization?.status != "active" {
                    NativeNotice(message: "Reactivate this organization before creating a key. Existing keys can still be reviewed and revoked.", tone: .info)
                }
                if !error.isEmpty {
                    NativeNotice(message: error, title: "API-key request failed", tone: .error)
                }
                if !notice.isEmpty { NativeNotice(message: notice, tone: .success) }
            }

            if let oneTimeSecret {
                NativeGroupPanel(title: "Save this key now", subtitle: "The full secret is shown once and is not stored by Desktop.") {
                    Text(oneTimeSecret)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ActionButton(title: "Done · I saved the key", icon: "checkmark") { self.oneTimeSecret = nil }
                }
            }

            NativeGroupPanel(title: "Keys", subtitle: "Active and revoked keys for \(organization?.name ?? "the selected organization")") {
                if loading && keys.isEmpty {
                    NativeEmptyState(title: "Loading API keys", message: "Checking the current organization membership and key list.")
                } else if keys.isEmpty && !error.isEmpty {
                    NativeEmptyState(title: "Keys unavailable", message: "Refresh after checking your organization access.")
                } else if keys.isEmpty {
                    NativeEmptyState(title: "No API keys", message: "Create a key for an integration that needs organization public API access.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(keys) { key in keyCard(key) }
                    }
                }
            }
        }
    }

    private func keyCard(_ key: OrganizationApiKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(key.name).font(.system(size: 14, weight: .bold)).foregroundStyle(theme.text)
                Spacer(minLength: 8)
                Text(key.enabled ? (isExpired(key) ? "Expired" : "Active") : "Revoked")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(key.enabled && !isExpired(key) ? theme.green : theme.textTertiary)
            }
            Text("hsk_\(key.keyPrefix)_••••••••")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
            Text("Expires \(date(key.expiresAt)) · Last used \(date(key.lastUsedAt))")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !key.scopes.isEmpty {
                ForEach(key.scopes) { scope in
                    Text("\(scope.method) \(scope.route) · \(scope.enabled ? "Enabled" : "Disabled")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if key.enabled {
                ActionButton(title: "Revoke", icon: "xmark.shield", tone: .danger) {
                    pendingAction = .revoke(key)
                }
                .disabled(busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var pendingActionIsRevoke: Bool {
        if case .revoke = pendingAction { return true }
        return false
    }
    private var dialogTitle: String { pendingActionIsRevoke ? "Revoke organization API key?" : "Create organization API key?" }
    private var dialogButtonTitle: String { pendingActionIsRevoke ? "Revoke key" : "Create key" }
    private var dialogMessage: String {
        switch pendingAction {
        case let .create(name): return "Create \(name) for \(organization?.name ?? "the selected organization")? The full key is shown once and expires in 90 days."
        case let .revoke(key): return "Revoke \(key.name)? Any clients using this key will stop working."
        case nil: return ""
        }
    }

    private func refresh() async {
        guard mayManage else { error = OrganizationApiKeyError.organizationScopeChanged.localizedDescription; return }
        loading = true
        error = ""
        notice = ""
        oneTimeSecret = nil
        defer { loading = false }
        do {
            let client = try apiKeyClient()
            let loaded = try await client.list()
            guard currentScopeIsSame() else { keys = []; return }
            keys = loaded
            needsReview = false
        } catch {
            if currentScopeIsSame() { self.error = error.localizedDescription }
        }
    }

    private func perform(_ action: OrganizationApiKeyPendingAction) async {
        guard mayManage, !busy else { return }
        busy = true
        error = ""
        notice = ""
        defer { busy = false }
        do {
            let client = try apiKeyClient()
            switch action {
            case let .create(name):
                let result = try await client.create(name: name)
                guard currentScopeIsSame() else { oneTimeSecret = nil; return }
                keys.insert(result.apiKey, at: 0)
                nameDraft = ""
                oneTimeSecret = result.secret
                needsReview = false
            case let .revoke(key):
                let receipt = try await client.revoke(key)
                guard currentScopeIsSame() else { return }
                if let index = keys.firstIndex(where: { $0.id == receipt.id }) { keys[index] = receipt }
                notice = "\(receipt.name) was revoked."
            }
        } catch {
            guard currentScopeIsSame() else { return }
            let requestError = error.localizedDescription
            if case .create = action { needsReview = true }
            await refresh()
            self.error = requestError
            if case .create = action { needsReview = true }
        }
    }

    private func currentScopeIsSame() -> Bool {
        mayManage && model.selectedOrganizationID == organizationID
    }

    private func apiKeyClient() throws -> OrganizationApiKeyClient {
        var settings = model.settings
        settings.userID = model.userIDForRequests
        settings.authToken = model.authTokenForRequests
        return try OrganizationApiKeyClient(settings: settings, organizationID: organizationID)
    }

    private func isExpired(_ key: OrganizationApiKey) -> Bool {
        guard let expiresAt = key.expiresAt, let date = parseDate(expiresAt) else { return false }
        return date <= Date()
    }

    private func date(_ value: String?) -> String {
        guard let value, let date = parseDate(value) else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
