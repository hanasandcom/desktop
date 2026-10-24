import SwiftUI

struct IntelligenceCasesNativePanel: View {
    let initialCaseID: String

    init(initialCaseID: String = "") {
        self.initialCaseID = initialCaseID
    }

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var page: IntelligenceCasePage?
    @State private var detail: IntelligenceCaseDetailEnvelope?
    @State private var cursor: String?
    @State private var query = ""
    @State private var statusFilter = "active"
    @State private var selectedID = ""
    @State private var note = ""
    @State private var owner = ""
    @State private var pendingAction: IntelligenceCaseAction?
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var error = ""
    @State private var notice = ""
    @State private var epoch = 0

    private var visibleCases: [IntelligenceCaseRow] {
        (page?.items ?? []).filter { item in
            let active = !["resolved", "closed", "suppressed", "false_positive"].contains(item.status.lowercased())
            let matchesStatus = statusFilter == "all" || (statusFilter == "active" ? active : item.status == statusFilter)
            let text = [item.id, item.title, item.summary, item.assignedOwner, item.severity].joined(separator: " ").localizedLowercase
            return matchesStatus && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.contains(query.localizedLowercase))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var routeOrganizationID: String? { model.nativeCaseHandoffContext?.organizationID }
    private var workspaceKey: String { [model.settings.websiteBaseURL, model.userIDForRequests, model.selectedOrganizationID, routeOrganizationID ?? "", model.hasHanasandAuth ? "signed-in" : "signed-out"].joined(separator: "|") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Intelligence Cases", subtitle: model.selectedOrganizationID.isEmpty ? "Personal case workspace" : "Organization · \(model.selectedOrganizationID)") {
                HStack(spacing: 8) {
                    SearchFieldRow(placeholder: "Search title, summary, owner, or ID", text: $query)
                    Picker("Case status", selection: $statusFilter) {
                        Text("Active").tag("active")
                        Text("All").tag("all")
                        ForEach(["open", "in_progress", "escalated", "resolved", "closed", "suppressed", "false_positive"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                    }.frame(width: 150)
                    ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load(reset: true) } }.disabled(isLoading || isWriting)
                }
                if let page {
                    Text("\(visibleCases.count) shown · \(page.items.count) loaded\(page.total.map { " · \($0) total" } ?? "")")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                if isLoading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading intelligence cases…").font(.system(size: 11)).foregroundStyle(theme.textSecondary) } }
                if !error.isEmpty { NativeNotice(message: error); ActionButton(title: "Retry", icon: "arrow.clockwise") { Task { await load(reset: page == nil) } }.disabled(isLoading) }
                if !notice.isEmpty { Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary) }
            }

            if let detail { caseDetail(detail) }
            else if let page, visibleCases.isEmpty, !isLoading {
                NativeEmptyState(title: page.items.isEmpty ? "No intelligence cases" : "No matching cases", message: page.items.isEmpty ? "Cases created from threat intelligence appear here." : "Change the search or status filter.")
            } else if page == nil && !isLoading && error.isEmpty {
                NativeEmptyState(title: model.hasHanasandAuth ? "Cases not loaded" : "Sign in required", message: "Sign in to view intelligence cases in the selected workspace.")
            }

            if detail == nil, page != nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(visibleCases) { item in
                        NativeGroupPanel(title: item.title, subtitle: "\(item.severity.isEmpty ? "Severity not recorded" : item.severity.capitalized) · \(item.status.replacingOccurrences(of: "_", with: " ").capitalized)") {
                            if !item.summary.isEmpty { Text(item.summary).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(4).textSelection(.enabled) }
                            Text("\(item.id) · \(item.assignedOwner.isEmpty ? "Unassigned" : item.assignedOwner) · Updated \(item.updatedAt.isEmpty ? "time unavailable" : item.updatedAt)")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(2).textSelection(.enabled)
                            ActionButton(title: "Open case", icon: "arrow.right") { Task { await open(item.id) } }
                        }
                    }
                }
                if let page, page.nextCursor != nil {
                    ActionButton(title: "Load more cases", icon: "arrow.down") { Task { await load(reset: false) } }.disabled(isLoading)
                }
            }
        }
        .task {
            if !initialCaseID.isEmpty { await open(initialCaseID) }
            else if page == nil && error.isEmpty { await load(reset: true) }
        }
        .onChange(of: workspaceKey) { _, _ in
            epoch += 1; isLoading = false; isWriting = false; page = nil; detail = nil; cursor = nil; selectedID = ""; error = ""; notice = ""; note = ""; owner = ""
            Task { await load(reset: true) }
        }
        .confirmationDialog(pendingAction?.label ?? "Confirm case action", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(pendingAction?.label ?? "Confirm", role: .destructive) { let action = pendingAction; pendingAction = nil; if let action { Task { await perform(action) } } }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("Record this action in the case workflow and refresh the timeline afterward?")
        }
    }

    @ViewBuilder private func caseDetail(_ value: IntelligenceCaseDetailEnvelope) -> some View {
        ActionButton(title: "Back to intelligence cases", icon: "chevron.left") { detail = nil; selectedID = ""; note = ""; notice = ""; error = "" }
        NativeGroupPanel(title: value.caseRecord.title, subtitle: "\(value.caseRecord.id) · \(value.caseRecord.status.replacingOccurrences(of: "_", with: " ").capitalized) · \(value.caseRecord.severity.isEmpty ? "Severity not recorded" : value.caseRecord.severity.capitalized)") {
            if !value.caseRecord.summary.isEmpty { Text(value.caseRecord.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            Text("Owner: \(value.caseRecord.assignedOwner.isEmpty ? "Unassigned" : value.caseRecord.assignedOwner) · Created: \(value.caseRecord.createdAt.isEmpty ? "Not recorded" : value.caseRecord.createdAt) · Updated: \(value.caseRecord.updatedAt.isEmpty ? "Not recorded" : value.caseRecord.updatedAt)")
                .font(.system(size: 11)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            if let resolution = value.caseRecord.raw["resolution"], resolution != .null {
                NativeGroupPanel(title: "Resolution", subtitle: resolution["type"]?.stringValue.isEmpty == false ? resolution["type"]!.stringValue.capitalized : "Recorded") {
                    ForEach(Array(resolution.objectValue.keys.sorted()), id: \.self) { key in field(key, resolution[key]!) }
                }
            }
        }

        NativeGroupPanel(title: "Analyst actions", subtitle: value.readOnly || !model.settings.impersonationToken.isEmpty ? "Read-only in this session" : "Actions allowed by current case policy") {
            TextField("Assigned owner", text: $owner).textFieldStyle(.roundedBorder).disabled(isWriting || value.readOnly)
            TextField("Rationale or comment", text: $note, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).disabled(isWriting || value.readOnly)
            if value.actions.isEmpty { Text("No workflow actions are currently available.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            ForEach(value.actions) { action in
                HStack(alignment: .center, spacing: 8) {
                    ActionButton(title: isWriting ? "Saving…" : action.label, icon: "checkmark") { pendingAction = action }
                        .disabled(isWriting || value.readOnly || !model.settings.impersonationToken.isEmpty || !action.enabled || action.method.uppercased() != "PATCH" || action.requiresRationale && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !action.enabled, !action.disabledReason.isEmpty { Text(action.disabledReason).font(.system(size: 10)).foregroundStyle(theme.textTertiary).lineLimit(2) }
                }
            }
        }

        NativeGroupPanel(title: "Case history and comments", subtitle: "\(value.timeline.count) recorded events") {
            if value.timeline.isEmpty { Text("No case history has been recorded.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            ForEach(Array(value.timeline.enumerated()), id: \.offset) { _, event in
                NativeGroupPanel(title: event["action"]?.stringValue.replacingOccurrences(of: "_", with: " ").capitalized ?? "Case event", subtitle: event["at"]?.stringValue ?? "Time not recorded") {
                    if let actor = event["actor"]?.stringValue, !actor.isEmpty { Text("By \(actor)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary) }
                    if let note = event["note"]?.stringValue, !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
                    ForEach(["fromStatus", "toStatus", "fromOwner", "toOwner"], id: \.self) { key in if let item = event[key], !item.stringValue.isEmpty { field(key, item) } }
                }
            }
        }

        NativeGroupPanel(title: "Evidence", subtitle: "\(value.evidence.count) attached records") {
            if value.evidence.isEmpty { Text("No evidence rows are attached to this case.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            ForEach(Array(value.evidence.enumerated()), id: \.offset) { index, evidence in
                NativeGroupPanel(title: evidence["sourceName"]?.stringValue.isEmpty == false ? evidence["sourceName"]!.stringValue : evidence["title"]?.stringValue.isEmpty == false ? evidence["title"]!.stringValue : "Evidence \(index + 1)", subtitle: evidence["sourceType"]?.stringValue ?? evidence["kind"]?.stringValue ?? "Evidence metadata") {
                    ForEach(Array(evidence.objectValue.keys.sorted()), id: \.self) { key in field(key, evidence[key]!) }
                }
            }
        }

        CasesDevelopmentNativePanel(caseID: value.caseRecord.id, organizationID: routeOrganizationID ?? model.selectedOrganizationID)
    }

    @ViewBuilder private func field(_ key: String, _ value: IntelligenceCaseJSON) -> some View {
        let rendered: String = switch value {
        case .string(let string): string
        case .number(let number): String(number)
        case .bool(let flag): flag ? "Yes" : "No"
        case .null: "Not recorded"
        case .array(let values): values.map { $0.stringValue.isEmpty ? String(describing: $0) : $0.stringValue }.joined(separator: ", ")
        case .object: "Structured value"
        }
        if !rendered.isEmpty { Text("\(key.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized): \(rendered)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }

    @MainActor private func load(reset: Bool) async {
        guard !isLoading else { return }
        let currentEpoch = epoch
        isLoading = true; error = ""; notice = ""
        do {
            let client = try IntelligenceCasesClient(settings: model.settings, organizationIDOverride: routeOrganizationID)
            let requestedCursor = reset ? nil : cursor
            let result = try await client.load(cursor: requestedCursor)
            guard currentEpoch == epoch, workspaceKey == [model.settings.websiteBaseURL, model.userIDForRequests, model.selectedOrganizationID, routeOrganizationID ?? "", model.hasHanasandAuth ? "signed-in" : "signed-out"].joined(separator: "|") else { throw IntelligenceCasesError.scopeChanged }
            if reset { page = result } else if let previous = page {
                let merged = Dictionary((previous.items + result.items).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.updatedAt > $1.updatedAt }
                page = IntelligenceCasePage(items: Array(merged), nextCursor: result.nextCursor, total: result.total)
            } else { page = result }
            cursor = result.nextCursor
            if !selectedID.isEmpty { detail = try await client.detail(caseID: selectedID) }
        } catch { if currentEpoch == epoch { self.error = error.localizedDescription } }
        isLoading = false
    }

    @MainActor private func open(_ id: String) async {
        selectedID = id; isLoading = true; error = ""; notice = ""; note = ""
        do {
            let client = try IntelligenceCasesClient(settings: model.settings, organizationIDOverride: routeOrganizationID)
            let result = try await client.detail(caseID: id)
            guard result.caseRecord.id == selectedID else { throw IntelligenceCasesError.scopeChanged }
            detail = result; owner = result.caseRecord.assignedOwner
        } catch { self.error = error.localizedDescription; selectedID = "" }
        isLoading = false
    }

    @MainActor private func perform(_ action: IntelligenceCaseAction) async {
        guard let current = detail, !current.readOnly else { return }
        isWriting = true; error = ""; notice = ""
        do {
            let settings = model.settings
            let client = try IntelligenceCasesClient(settings: settings, organizationIDOverride: routeOrganizationID)
            try await client.perform(action, caseRecord: current.caseRecord, alertID: current.alertContext["id"]?.stringValue, note: note, assignedOwner: owner, currentSettings: model.settings)
            guard detail?.caseRecord.id == current.caseRecord.id else { throw IntelligenceCasesError.scopeChanged }
            detail = try await client.detail(caseID: current.caseRecord.id)
            owner = detail?.caseRecord.assignedOwner ?? owner
            note = ""
            notice = "\(action.label) recorded. Case history refreshed."
            page = try await client.load()
            cursor = page?.nextCursor
        } catch { self.error = error.localizedDescription }
        isWriting = false
    }
}
