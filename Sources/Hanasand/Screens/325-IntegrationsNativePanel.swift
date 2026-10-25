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
    @State private var scopeLifecycle = IntegrationScopeLifecycle()
    @State private var draftScopeIdentity: IntegrationScopeIdentity?
    @State private var pageScopeIdentity: IntegrationScopeIdentity?
    @State private var refreshRequired = false

    private var scopeID: String { initialOrganizationID ?? model.selectedOrganizationID }
    private var scopeIdentity: IntegrationScopeIdentity {
        IntegrationScopeIdentity(
            apiBaseURL: model.settings.apiBaseURL,
            workspaceID: scopeID,
            userID: model.userIDForRequests,
            authToken: model.authTokenForRequests,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }
    private var personal: Bool { scopeID.isEmpty || scopeID == "personal" || scopeID == model.userIDForRequests }
    private var isImpersonating: Bool { !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty }
    private var canManage: Bool { pageScopeIdentity == scopeIdentity && !isImpersonating && page?.destinationAdminProof.access?.canManage == true }
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { refreshButton; addDestinationButton }
                    VStack(alignment: .leading, spacing: 8) { refreshButton; addDestinationButton }
                }
                TextField("Search destinations", text: $search).textFieldStyle(.roundedBorder)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { typeFilterControl; statusFilterControl }
                    VStack(alignment: .leading, spacing: 8) { typeFilterControl; statusFilterControl }
                }
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
        .task(id: IntegrationLoadTaskKey(scope: scopeIdentity, revision: revision)) { await load() }
        .onChange(of: scopeIdentity) { _, identity in
            guard scopeLifecycle.update(to: identity) else { return }
            resetForScopeChange()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                // Integration drafts contain destination URLs. Clear them when the app
                // leaves the foreground and require a fresh permission read on return.
                draft = nil
                draftScopeIdentity = nil
                page = nil
                pageScopeIdentity = nil
                pendingAction = nil
                error = ""
                notice = ""
                warning = ""
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { latestTestDetails(latestTest) }
                    VStack(alignment: .leading, spacing: 6) { latestTestDetails(latestTest) }
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { destinationEditButton(destination, page: page); destinationTestButton(destination, page: page); destinationRemoveButton(destination, page: page) }
                VStack(alignment: .leading, spacing: 8) { destinationEditButton(destination, page: page); destinationTestButton(destination, page: page); destinationRemoveButton(destination, page: page) }
            }
        }.padding(.vertical, 6)
    }

    private var refreshButton: some View {
        ActionButton(title: busy ? "Working…" : "Refresh", icon: "arrow.clockwise") { revision += 1 }.disabled(busy)
    }

    private var addDestinationButton: some View {
        ActionButton(title: "Add destination", icon: "plus") { beginNew() }.disabled(busy || !canManage || refreshRequired)
    }

    private var typeFilterControl: some View {
        Picker("Type", selection: $typeFilter) {
            Text("All types").tag("")
            ForEach(IntegrationKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
        }.pickerStyle(.segmented)
    }

    private var statusFilterControl: some View {
        Picker("Status", selection: $statusFilter) {
            Text("All statuses").tag("")
            Text("Active").tag("active")
            Text("Paused").tag("paused")
        }.pickerStyle(.segmented)
    }

    @ViewBuilder private func destinationEditButton(_ destination: IntegrationDestination, page: IntegrationPage) -> some View {
        ActionButton(title: "Edit", icon: "pencil") { beginEdit(destination) }.disabled(busy || !canManage || !permission(destination.id, page: page, keyPath: \.canUpdate))
    }

    @ViewBuilder private func destinationTestButton(_ destination: IntegrationDestination, page: IntegrationPage) -> some View {
        ActionButton(title: "Test", icon: "paperplane") { pendingAction = PendingAction(kind: .test, destination: destination, scopeIdentity: scopeIdentity) }.disabled(busy || !canManage || !testAllowed(destination.id, page: page))
    }

    @ViewBuilder private func destinationRemoveButton(_ destination: IntegrationDestination, page: IntegrationPage) -> some View {
        ActionButton(title: "Remove", icon: "archivebox") { pendingAction = PendingAction(kind: .archive, destination: destination, scopeIdentity: scopeIdentity) }.disabled(busy || !canManage || !permission(destination.id, page: page, keyPath: \.canDisable))
    }

    @ViewBuilder private func editor(_ draft: IntegrationDraft) -> some View {
        NativeGroupPanel(title: draft.id == nil ? "New destination" : "Edit destination", subtitle: "Saved destination URL is hidden; leave it blank to keep the current URL.") {
            TextField("Name", text: Binding(get: { draft.name }, set: { self.draft?.name = $0 })).textFieldStyle(.roundedBorder).disabled(busy || !canManage)
            Picker("Type", selection: Binding(get: { draft.kind }, set: { self.draft?.kind = $0 })) { ForEach(IntegrationKind.allCases) { Text($0.title).tag($0) } }.disabled(busy || !canManage)
            SecureField("Webhook URL", text: Binding(get: { draft.endpointURL }, set: { self.draft?.endpointURL = $0 }))
                .textFieldStyle(.roundedBorder).disabled(busy || !canManage)
            Text("Discord destinations require an HTTPS Discord webhook URL. URLs are not shown after saving.")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { saveDestinationButton(draft); cancelEditButton }
                VStack(alignment: .leading, spacing: 8) { saveDestinationButton(draft); cancelEditButton }
            }
        }
    }

    @ViewBuilder private func latestTestDetails(_ test: IntegrationLatestTest) -> some View {
        if let dryRun = test.dryRun { Label(dryRun ? "Dry run" : "Live test", systemImage: dryRun ? "checkmark.shield" : "paperplane") }
        if let responseStatus = test.responseStatus { Text("HTTP \(responseStatus)") }
        if let source = test.source { Text(source.replacingOccurrences(of: "_", with: " ")) }
    }

    private func saveDestinationButton(_ draft: IntegrationDraft) -> some View {
        ActionButton(title: busy ? "Saving…" : "Save destination", icon: "checkmark") { Task { await save() } }.disabled(busy || !canManage || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var cancelEditButton: some View {
        ActionButton(title: "Cancel", icon: "xmark") { draft = nil; draftScopeIdentity = nil }.disabled(busy)
    }

    private func beginNew() {
        draft = IntegrationDraft(id: nil, name: "", kind: .discord, endpointURL: "")
        draftScopeIdentity = scopeIdentity
        error = ""; notice = ""
    }
    private func beginEdit(_ destination: IntegrationDestination) {
        draft = IntegrationDraft(id: destination.id, name: destination.name, kind: destination.kind, endpointURL: "")
        draftScopeIdentity = scopeIdentity
        error = ""; notice = ""
    }

    private func resetForScopeChange() {
        draft = nil
        draftScopeIdentity = nil
        page = nil
        pageScopeIdentity = nil
        pendingAction = nil
        error = ""
        notice = ""
        warning = ""
        refreshRequired = true
        revision += 1
    }

    private func load() async {
        guard model.hasHanasandAuth else { page = nil; pageScopeIdentity = nil; return }
        let requestIdentity = scopeIdentity
        if scopeLifecycle.update(to: requestIdentity) { resetForScopeChange() }
        let requestGeneration = scopeLifecycle.generation
        let requestScope = scopeID
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
            guard scenePhase == .active, scopeIdentity == requestIdentity,
                  scopeLifecycle.identity == requestIdentity, scopeLifecycle.generation == requestGeneration,
                  revision == requestRevision, loadRequestID == requestID else { return }
            guard requestScope.isEmpty || loaded.destinations.allSatisfy({ $0.orgId == (requestScope == "personal" ? requestIdentity.userID : requestScope) }) else { throw IntegrationClientError.invalidResponse }
            pageScopeIdentity = requestIdentity
            page = loaded; refreshRequired = false
        } catch {
            guard scenePhase == .active, scopeIdentity == requestIdentity,
                  scopeLifecycle.identity == requestIdentity, scopeLifecycle.generation == requestGeneration,
                  revision == requestRevision, loadRequestID == requestID else { return }
            page = nil; pageScopeIdentity = nil; self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let draft, let page, draftScopeIdentity == scopeIdentity, pageScopeIdentity == scopeIdentity else { return }
        let requestIdentity = scopeIdentity
        busy = true; error = ""; notice = ""; warning = ""; defer { busy = false }
        do {
            try await makeClient().save(page: page, draft: draft)
            guard scopeIdentity == requestIdentity else { return }
            self.draft = nil; draftScopeIdentity = nil; notice = "Destination saved."; revision += 1
        } catch {
            guard scopeIdentity == requestIdentity else { return }
            self.error = error.localizedDescription
            if error is IntegrationClientError { refreshRequired = true }
        }
    }

    private func perform(_ action: PendingAction) async {
        guard let page, action.scopeIdentity == scopeIdentity, pageScopeIdentity == scopeIdentity else { return }
        let requestIdentity = scopeIdentity
        pendingAction = nil; busy = true; error = ""; notice = ""; warning = ""; defer { busy = false }
        do {
            let client = try makeClient()
            let testResult: (Bool, String)?
            if action.kind == .archive {
                try await client.archive(page: page, destination: action.destination)
                testResult = nil
            } else { testResult = try await client.test(page: page, destination: action.destination) }
            guard scopeIdentity == requestIdentity else { return }
            if let (delivered, message) = testResult {
                if delivered { notice = message } else { warning = message }
            } else { notice = "Destination archived." }
            revision += 1
        } catch {
            guard scopeIdentity == requestIdentity else { return }
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
    let scopeIdentity: IntegrationScopeIdentity
    var title: String { kind == .test ? "Test destination?" : "Remove destination?" }
    var message: String { kind == .test ? "This sends an example message to the configured destination." : "This archives the destination." }
}

struct IntegrationScopeIdentity: Hashable {
    let apiBaseURL: String
    let workspaceID: String
    let userID: String
    let authToken: String
    let impersonationToken: String
    let impersonatingUserID: String
}

struct IntegrationScopeLifecycle: Equatable {
    private(set) var identity: IntegrationScopeIdentity? = nil
    private(set) var generation = 0

    @discardableResult
    mutating func update(to identity: IntegrationScopeIdentity) -> Bool {
        guard let current = self.identity else {
            self.identity = identity
            return false
        }
        guard current != identity else { return false }
        self.identity = identity
        generation += 1
        return true
    }
}

private struct IntegrationLoadTaskKey: Hashable {
    let scope: IntegrationScopeIdentity
    let revision: Int
}
