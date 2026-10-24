import SwiftUI

enum ServiceAccountHistory {
    static func includes(_ account: ServiceAccountRecord, includeRevoked: Bool) -> Bool {
        includeRevoked || account.active
    }

    static func visibleAccounts(_ accounts: [ServiceAccountRecord], query: String, descending: Bool, includeRevoked: Bool) -> [ServiceAccountRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return accounts.filter { account in
            includes(account, includeRevoked: includeRevoked)
                && (needle.isEmpty || [account.name, account.id, account.description, account.keys.flatMap { $0.scopes.map { "\($0.method) \($0.route) \($0.label ?? "")" } }.joined(separator: " ")]
                    .contains { $0.lowercased().contains(needle) })
        }
        .sorted { descending ? $0.name.localizedStandardCompare($1.name) == .orderedDescending : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func canMutate(_ account: ServiceAccountRecord, writerAllowed: Bool) -> Bool {
        writerAllowed && account.active
    }
}

struct ServiceAccountsNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var directory: ServiceAccountDirectory?
    @State private var access: ServiceAccountAccess?
    @State private var selectedID: String?
    @State private var search = ""
    @State private var descending = false
    @State private var includeRevoked = false
    @State private var name = ""
    @State private var description = ""
    @State private var scopeQuery = ""
    @State private var selectedScopes: Set<String> = []
    @State private var secret = ""
    @State private var secretCopyMessage = ""
    @State private var error = ""
    @State private var message = ""
    @State private var loading = false
    @State private var busy = false
    @State private var reconciliationRequired = false
    @State private var revision = 0
    @State private var pending: PendingAction?

    private enum PendingAction: String, Identifiable {
        case create, update, revoke
        var id: String { rawValue }
    }

    private var scope: String {
        "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(model.authTokenForRequests)|\(model.settings.impersonationToken)|\(revision)"
    }

    private var isImpersonating: Bool { !model.settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canWrite: Bool { access?.allowed == true && access?.canEdit == true && !isImpersonating && !busy && !loading && !reconciliationRequired }
    private var selectedAccount: ServiceAccountRecord? {
        guard let account = directory?.accounts.first(where: { $0.id == selectedID }),
              ServiceAccountHistory.includes(account, includeRevoked: includeRevoked) else { return nil }
        return account
    }
    private var visibleAccounts: [ServiceAccountRecord] {
        ServiceAccountHistory.visibleAccounts(directory?.accounts ?? [], query: search, descending: descending, includeRevoked: includeRevoked)
    }

    private var matchingAccountCountDescription: String {
        let total = directory?.accounts.filter { includeRevoked || $0.active }.count ?? 0
        return "\(visibleAccounts.count) matching of \(total) \(includeRevoked ? "retained" : "active") accounts"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hanasand administration · global service accounts").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    Text("Credentials are shown only once. Revocation disables every key and retains usage history.").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                ActionButton(title: loading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { revision += 1 }
                    .disabled(loading || busy)
            }
            if loading && directory == nil {
                ProgressView("Loading service accounts…").frame(maxWidth: .infinity, alignment: .leading).padding(16).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            }
            if !error.isEmpty { NativeEmptyState(title: "Service accounts", message: error) }
            if !message.isEmpty { Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
            if isImpersonating { Label("Changes are disabled during impersonation.", systemImage: "person.crop.circle.badge.xmark").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
            if let access, access.allowed, !access.canEdit { Label("Read-only access. Current Hanasand owner or editor access is required for changes.", systemImage: "lock").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
            if let directory {
                NativeGroupPanel(title: "Current accounts", subtitle: matchingAccountCountDescription) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            TextField("Search name, ID, description, or endpoint", text: $search).textFieldStyle(.roundedBorder)
                            ActionButton(title: descending ? "Name Z–A" : "Name A–Z", icon: "arrow.up.arrow.down") { descending.toggle() }
                            Toggle("Include revoked history", isOn: $includeRevoked).toggleStyle(.checkbox)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Search name, ID, description, or endpoint", text: $search).textFieldStyle(.roundedBorder)
                            ActionButton(title: descending ? "Name Z–A" : "Name A–Z", icon: "arrow.up.arrow.down") { descending.toggle() }
                            Toggle("Include revoked history", isOn: $includeRevoked).toggleStyle(.checkbox)
                        }
                    }
                    if visibleAccounts.isEmpty {
                        Text(includeRevoked ? "No service accounts match this view." : "No active service accounts match this view. Include revoked history to inspect past accounts.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(visibleAccounts) { account in
                            Button {
                                selectedID = account.id
                                name = account.name
                                description = account.description
                                secret = ""
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(account.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                                        Text("\(account.keys.count) keys · \(account.keys.flatMap(\.scopes).count) endpoint grants · created \(account.createdAt ?? "unknown")")
                                            .font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(2)
                                    }
                                    Spacer()
                                    if selectedID == account.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                                }.contentShape(Rectangle()).padding(.vertical, 3)
                            }.buttonStyle(.plain)
                            if account.id != visibleAccounts.last?.id { Divider() }
                        }
                    }
                }
                if let account = selectedAccount { accountPanel(account) }
                createPanel(directory)
            }
            if !secret.isEmpty {
                NativeGroupPanel(title: "Save this key now", subtitle: "It cannot be recovered after this panel closes or you refresh.") {
                    Text("Send it in the X-API-Key request header.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    Text(secret).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        ActionButton(title: secretCopyMessage == "Copied" ? "Copied" : "Copy key", icon: secretCopyMessage == "Copied" ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            if NSPasteboard.general.setString(secret, forType: .string) {
                                secretCopyMessage = "Copied"
                            } else {
                                secretCopyMessage = "Could not copy key. Select the text above and press Command-C."
                            }
                        }
                        ActionButton(title: "Dismiss key", icon: "xmark") { secret = ""; secretCopyMessage = "" }
                    }
                    if !secretCopyMessage.isEmpty && secretCopyMessage != "Copied" {
                        Text(secretCopyMessage).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .task(id: scope) { await refresh() }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { secret = ""; secretCopyMessage = "" }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(dialogConfirm, role: pending == .revoke ? .destructive : nil) { let action = pending; pending = nil; Task { await perform(action) } }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text(dialogMessage) }
    }

    @ViewBuilder private func accountPanel(_ account: ServiceAccountRecord) -> some View {
        let accountCanWrite = ServiceAccountHistory.canMutate(account, writerAllowed: canWrite)
        NativeGroupPanel(title: account.name, subtitle: "\(account.id) · \(account.active ? "Active" : "Revoked")") {
            TextField("Account name", text: $name).textFieldStyle(.roundedBorder).disabled(!accountCanWrite)
            TextField("Description", text: $description, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(!accountCanWrite)
            Text("Created \(account.createdAt ?? "unknown"). Key secrets are never returned by the service.").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            ForEach(account.keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key \(key.keyPrefix) · \(key.enabled ? "Enabled" : "Disabled")").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Created \(key.createdAt ?? "unknown") · last used \(key.lastUsedAt ?? "Never")").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    ForEach(key.scopes) { item in
                        Text("\(item.method) \(item.route)\(item.enabled ? "" : " · Disabled")\(item.label.map { " · \($0)" } ?? "")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                ActionButton(title: busy ? "Saving…" : "Review update", icon: "pencil") { pending = .update }
                    .disabled(!accountCanWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (name == account.name && description == account.description))
                ActionButton(title: "Review revocation", icon: "xmark.circle", tone: .danger) { pending = .revoke }.disabled(!accountCanWrite)
            }
        }
    }

    @ViewBuilder private func createPanel(_ directory: ServiceAccountDirectory) -> some View {
        NativeGroupPanel(title: "Create service account", subtitle: "Choose only the endpoint grants this account needs.") {
            TextField("Name (up to 100 characters)", text: $nameForCreate).textFieldStyle(.roundedBorder).disabled(!canWrite)
            TextField("Description (optional)", text: $descriptionForCreate, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(!canWrite)
            TextField("Filter supported endpoints", text: $scopeQuery).textFieldStyle(.roundedBorder).disabled(!canWrite)
            Text("\(selectedScopes.count) endpoints selected · no wildcard scopes are added").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            ForEach(directory.endpoints.filter { scopeQuery.isEmpty || "\($0.method) \($0.route) \($0.label)".localizedCaseInsensitiveContains(scopeQuery) }) { endpoint in
                Toggle(isOn: Binding(get: { selectedScopes.contains(endpoint.id) }, set: { enabled in if enabled { selectedScopes.insert(endpoint.id) } else { selectedScopes.remove(endpoint.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.label.isEmpty ? endpoint.id : endpoint.label).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                        Text(endpoint.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    }
                }.toggleStyle(.checkbox).disabled(!canWrite)
            }
            ActionButton(title: busy ? "Creating…" : "Review creation", icon: "plus") { pending = .create }
                .disabled(!canWrite || nameForCreate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedScopes.isEmpty)
        }
    }

    @State private var nameForCreate = ""
    @State private var descriptionForCreate = ""

    private var dialogTitle: String {
        switch pending { case .create: "Create service account?"; case .update: "Update service account?"; case .revoke: "Revoke service account?"; case nil: "Review change" }
    }
    private var dialogConfirm: String { pending == .create ? "Create" : pending == .update ? "Update" : "Revoke" }
    private var dialogMessage: String {
        switch pending {
        case .create: "Create \(nameForCreate.trimmingCharacters(in: .whitespacesAndNewlines)) with \(selectedScopes.count) selected endpoint grants. The new API key will be shown once."
        case .update: "Update \(selectedAccount?.name ?? "this account") to \(name.trimmingCharacters(in: .whitespacesAndNewlines)). Existing endpoint grants will not change."
        case .revoke: "Revoke \(selectedAccount?.name ?? "this account")? Every API key and session will be disabled. Usage history is retained."
        case nil: "Review the requested change."
        }
    }

    private func client() throws -> ServiceAccountsClient {
        guard let base = URL(string: model.settings.apiBaseURL) else { throw ServiceAccountsClientError.invalidBaseURL }
        return try ServiceAccountsClient(baseURL: base, userID: model.userIDForRequests, token: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken)
    }

    @MainActor private func refresh() async {
        guard model.hasHanasandAuth else { directory = nil; access = nil; error = "Sign in to view service accounts."; return }
        loading = true; error = ""; message = ""; secret = ""; secretCopyMessage = ""
        defer { loading = false }
        do {
            let client = try client()
            let rights = try await client.loadAccess()
            let result = try await client.loadDirectory()
            access = rights; directory = result
            reconciliationRequired = false
            if let selectedID, !result.accounts.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        } catch { directory = nil; access = nil; self.error = error.localizedDescription }
    }

    @MainActor private func perform(_ action: PendingAction?) async {
        guard let action else { return }
        busy = true; error = ""; message = ""; secret = ""
        defer { busy = false }
        do {
            let client = try client()
            let freshAccess = try await client.loadAccess()
            guard freshAccess.allowed, freshAccess.canEdit, !isImpersonating else { throw ServiceAccountsClientError.readOnly }
            switch action {
            case .create:
                guard let directory else { throw ServiceAccountsClientError.invalidResponse }
                let scopes = directory.endpoints.filter { selectedScopes.contains($0.id) }
                let receipt = try await client.create(access: freshAccess, name: nameForCreate, description: descriptionForCreate, scopes: scopes)
                secret = receipt.secret
                secretCopyMessage = ""
                nameForCreate = ""; descriptionForCreate = ""; selectedScopes.removeAll()
                await refreshKeepingSecret()
                message = "Created service account \(receipt.apiKey.ownerID). Save the key now; it cannot be recovered later."
            case .update:
                guard let account = selectedAccount else { throw ServiceAccountsClientError.invalidResponse }
                _ = try await client.update(access: freshAccess, id: account.id, name: name, description: description)
                await refresh()
                message = "Service account updated."
            case .revoke:
                guard let account = selectedAccount else { throw ServiceAccountsClientError.invalidResponse }
                let receipt = try await client.revoke(access: freshAccess, id: account.id)
                selectedID = nil
                await refresh()
                message = receipt.message
            }
        } catch {
            self.error = error.localizedDescription
            if (error as? ServiceAccountsClientError) == .unknownOutcome { reconciliationRequired = true }
        }
    }

    @MainActor private func refreshKeepingSecret() async {
        let key = secret
        await refresh()
        secret = key
    }
}
