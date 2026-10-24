import SwiftUI

struct IntegrationsNativePanel: View {
    var initialOrganizationID: String? = nil
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: IntegrationPage?
    @State private var draft: IntegrationDraft?
    @State private var search = ""
    @State private var typeFilter = ""
    @State private var statusFilter = ""
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""
    @State private var warning = ""
    @State private var pendingAction: PendingAction?
    @State private var revision = 0
    @State private var loadRequestID: UUID?
    @State private var refreshRequired = false

    private var scopeID: String { initialOrganizationID ?? model.selectedOrganizationID }
    private var personal: Bool { scopeID.isEmpty || scopeID == "personal" || scopeID == model.userIDForRequests }
    private var isImpersonating: Bool { !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty }
    private var canManage: Bool { !isImpersonating && page?.destinationAdminProof.access?.canManage == true }
    private var visible: [IntegrationDestination] {
        (page?.destinations ?? []).filter { item in
            item.status != "archived" && (typeFilter.isEmpty || item.kind.rawValue == typeFilter)
                && (statusFilter.isEmpty || item.status == statusFilter)
                && "\(item.name) \(item.endpointHint ?? "")".localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Integration destinations", subtitle: personal ? "Personal destinations" : "Organization destinations · \(scopeID)") {
                HStack(spacing: 8) {
                    ActionButton(title: busy ? "Working…" : "Refresh", icon: "arrow.clockwise") { revision += 1 }.disabled(busy)
                    ActionButton(title: "Add destination", icon: "plus") { beginNew() }.disabled(busy || !canManage || refreshRequired)
                }
                TextField("Search destinations", text: $search).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $typeFilter) {
                    Text("All types").tag("")
                    ForEach(IntegrationKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
                }.pickerStyle(.segmented)
                Picker("Status", selection: $statusFilter) {
                    Text("All statuses").tag("")
                    Text("Active").tag("active")
                    Text("Paused").tag("paused")
                }.pickerStyle(.segmented)
                if !error.isEmpty { Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled) }
                if !warning.isEmpty { NativeNotice(message: warning) }
                if !notice.isEmpty { NativeNotice(message: notice) }
                if refreshRequired { NativeNotice(message: "Refresh and review the current destinations before trying again. The previous change may have been saved.") }
                if !canManage && page != nil { NativeNotice(message: isImpersonating ? "Read-only while impersonating. Return to your own account before changing destinations." : "Destination management is unavailable for this account or workspace.") }
            }

            if let draft { editor(draft) }
            else if let page {
                NativeGroupPanel(title: "Destinations · \(visible.count)", subtitle: "Discord and webhook delivery targets") {
                    if visible.isEmpty { NativeEmptyState(title: "No destinations found", message: page.destinations.contains(where: { $0.status != "archived" }) ? "No destinations match this search or status." : "No delivery destinations are configured for this workspace.") }
                    ForEach(visible) { destination in destinationRow(destination, page: page) }
                }
            } else if busy { NativeEmptyState(title: "Loading integrations", message: "Checking the selected workspace and destination permissions.") }
            else { NativeEmptyState(title: model.hasHanasandAuth ? "Select an organization" : "Sign in required", message: model.hasHanasandAuth ? "Choose a workspace to review delivery destinations." : "Sign in to review integrations.") }
        }
        .task(id: "\(model.userIDForRequests):\(model.authTokenForRequests):\(scopeID):\(revision)") { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                // Integration drafts contain destination URLs. Clear them when the app
                // leaves the foreground and require a fresh permission read on return.
                draft = nil
                page = nil
                refreshRequired = true
            } else {
                revision += 1
            }
        }
        .confirmationDialog(pendingAction?.title ?? "Confirm destination action", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let pendingAction {
                Button(pendingAction.kind == .test ? "Send example message" : "Archive destination", role: pendingAction.kind == .archive ? .destructive : nil) { Task { await perform(pendingAction) } }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction?.message ?? "") }
    }

    @ViewBuilder private func destinationRow(_ destination: IntegrationDestination, page: IntegrationPage) -> some View {
        let test = page.destinationTests.first(where: { $0.destinationId == destination.id })
        let latestTest = test?.latestTest
        let testStatus = latestTest?.status ?? test?.status ?? destination.lastTestStatus
        VStack(alignment: .leading, spacing: 7) {
            Text(destination.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            Text("\(destination.kind.title) · \(destination.status.capitalized)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            Text(destination.endpointHint ?? "Configured destination").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            Text("Last test: \(testStatus?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not recorded")\(destination.lastTestedAt.map { " · \($0)" } ?? "")")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            if let latestTest {
                HStack(spacing: 6) {
                    if let dryRun = latestTest.dryRun { Label(dryRun ? "Dry run" : "Live test", systemImage: dryRun ? "checkmark.shield" : "paperplane") }
                    if let responseStatus = latestTest.responseStatus { Text("HTTP \(responseStatus)") }
                    if let source = latestTest.source { Text(source.replacingOccurrences(of: "_", with: " ")) }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                if let error = latestTest.error, !error.isEmpty {
                    Text("Last test detail: \(error)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            ForEach(test?.blockers ?? []) { blocker in
                Text("\(blocker.blocking == true ? "Blocked" : "Note")\(blocker.code.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""): \(blocker.message)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(blocker.blocking == true ? theme.danger : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                ActionButton(title: "Edit", icon: "pencil") { beginEdit(destination) }.disabled(busy || !canManage || !permission(destination.id, page: page, keyPath: \.canUpdate))
                ActionButton(title: "Test", icon: "paperplane") { pendingAction = PendingAction(kind: .test, destination: destination) }.disabled(busy || !canManage || !testAllowed(destination.id, page: page))
                ActionButton(title: "Remove", icon: "archivebox") { pendingAction = PendingAction(kind: .archive, destination: destination) }.disabled(busy || !canManage || !permission(destination.id, page: page, keyPath: \.canDisable))
            }
        }.padding(.vertical, 6)
    }

    @ViewBuilder private func editor(_ draft: IntegrationDraft) -> some View {
        NativeGroupPanel(title: draft.id == nil ? "New destination" : "Edit destination", subtitle: "Saved destination URL is hidden; leave it blank to keep the current URL.") {
            TextField("Name", text: Binding(get: { draft.name }, set: { self.draft?.name = $0 })).textFieldStyle(.roundedBorder).disabled(busy || !canManage)
            Picker("Type", selection: Binding(get: { draft.kind }, set: { self.draft?.kind = $0 })) { ForEach(IntegrationKind.allCases) { Text($0.title).tag($0) } }.disabled(busy || !canManage)
            SecureField("Webhook URL", text: Binding(get: { draft.endpointURL }, set: { self.draft?.endpointURL = $0 }))
                .textFieldStyle(.roundedBorder).disabled(busy || !canManage)
            Text("Discord destinations require an HTTPS Discord webhook URL. URLs are not shown after saving.")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ActionButton(title: busy ? "Saving…" : "Save destination", icon: "checkmark") { Task { await save() } }.disabled(busy || !canManage || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ActionButton(title: "Cancel", icon: "xmark") { self.draft = nil }.disabled(busy)
            }
        }
    }

    private func beginNew() { draft = IntegrationDraft(id: nil, name: "", kind: .discord, endpointURL: ""); error = ""; notice = "" }
    private func beginEdit(_ destination: IntegrationDestination) { draft = IntegrationDraft(id: destination.id, name: destination.name, kind: destination.kind, endpointURL: ""); error = ""; notice = "" }

    private func load() async {
        guard model.hasHanasandAuth else { page = nil; return }
        let requestScope = scopeID
        let requestUser = model.userIDForRequests
        let requestToken = model.authTokenForRequests
        let requestRevision = revision
        let requestID = UUID()
        loadRequestID = requestID
        busy = true; error = ""
        defer {
            if loadRequestID == requestID {
                loadRequestID = nil
                busy = false
            }
        }
        do {
            let client = try makeClient()
            let loaded = try await client.load()
            guard scenePhase == .active, scopeID == requestScope,
                  model.userIDForRequests == requestUser, model.authTokenForRequests == requestToken,
                  revision == requestRevision, loadRequestID == requestID else { return }
            guard requestScope.isEmpty || loaded.destinations.allSatisfy({ $0.orgId == (requestScope == "personal" ? requestUser : requestScope) }) else { throw IntegrationClientError.invalidResponse }
            page = loaded; refreshRequired = false
        } catch {
            guard scenePhase == .active, scopeID == requestScope,
                  model.userIDForRequests == requestUser, model.authTokenForRequests == requestToken,
                  revision == requestRevision, loadRequestID == requestID else { return }
            page = nil; self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let draft, let page else { return }
        busy = true; error = ""; notice = ""; warning = ""; defer { busy = false }
        do {
            try await makeClient().save(page: page, draft: draft)
            self.draft = nil; notice = "Destination saved."; revision += 1
        } catch {
            self.error = error.localizedDescription
            if error is IntegrationClientError { refreshRequired = true }
        }
    }

    private func perform(_ action: PendingAction) async {
        guard let page else { return }
        pendingAction = nil; busy = true; error = ""; notice = ""; warning = ""; defer { busy = false }
        do {
            let client = try makeClient()
            if action.kind == .archive { try await client.archive(page: page, destination: action.destination); notice = "Destination archived." }
            else {
                let (delivered, message) = try await client.test(page: page, destination: action.destination)
                if delivered { notice = message } else { warning = message }
            }
            revision += 1
        } catch {
            self.error = error.localizedDescription
            refreshRequired = true
        }
    }

    private func makeClient() throws -> IntegrationClient {
        guard let base = URL(string: model.settings.apiBaseURL) else { throw IntegrationClientError.invalidAPIURL }
        return try IntegrationClient(apiBaseURL: base, userID: model.userIDForRequests, token: model.authTokenForRequests,
                                     organizationID: scopeID, impersonationToken: model.settings.impersonationToken,
                                     impersonatingUserID: model.settings.impersonatingUserID)
    }

    private func permission(_ id: String, page: IntegrationPage, keyPath: KeyPath<IntegrationPermission, Bool?>) -> Bool {
        page.destinationLifecycle.first(where: { $0.destinationId == id })?.access?[keyPath: keyPath] == true
    }
    private func testAllowed(_ id: String, page: IntegrationPage) -> Bool {
        permission(id, page: page, keyPath: \.canTest)
            && page.destinationTests.first(where: { $0.destinationId == id })?.access?.canTest == true
            && !(page.destinationTests.first(where: { $0.destinationId == id })?.blockers ?? []).contains(where: { $0.blocking == true })
    }
}

private struct PendingAction {
    enum Kind { case archive, test }
    let kind: Kind
    let destination: IntegrationDestination
    var title: String { kind == .test ? "Test destination?" : "Remove destination?" }
    var message: String { kind == .test ? "This sends an example message to the configured destination." : "This archives the destination." }
}
