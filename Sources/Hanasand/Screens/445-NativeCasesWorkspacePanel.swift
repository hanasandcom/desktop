import SwiftUI

private struct CasesWorkspaceRow: Identifiable {
    let id: String
    let title: String
    let summary: String
    let status: String
    let severity: String
    let owner: String
    let updatedAt: String
    let source: String
    let monitoringCase: MonitoringCase?
    let intelligenceCase: IntelligenceCaseRow?

    init(_ value: MonitoringCase) {
        id = value.id; title = value.title; summary = value.summary; status = value.status
        severity = value.severity; owner = value.assignedOwner; updatedAt = value.updatedAt
        source = "monitoring"; monitoringCase = value; intelligenceCase = nil
    }

    init(_ value: IntelligenceCaseRow) {
        id = value.id; title = value.title; summary = value.summary; status = value.status
        severity = value.severity; owner = value.assignedOwner; updatedAt = value.updatedAt
        source = value.source.isEmpty ? "intelligence" : value.source; monitoringCase = nil; intelligenceCase = value
    }
}

struct CasesWorkspaceNativePanel: View {
    let initialCaseID: String
    init(initialCaseID: String = "") { self.initialCaseID = initialCaseID }

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var monitoringCases: [MonitoringCase] = []
    @State private var intelligencePage: IntelligenceCasePage?
    @State private var moreIntelligenceCases: [IntelligenceCaseRow] = []
    @State private var cursor: String?
    @State private var selectedID = ""
    @State private var search = ""
    @State private var status = "active"
    @State private var severity = "all"
    @State private var source = "all"
    @State private var owner = "all"
    @State private var resolution = "all"
    @State private var review = "all"
    @State private var selectedForMerge: Set<String> = []
    @State private var mergeTarget = ""
    @State private var pendingMerge = false
    @State private var pendingCreate = false
    @State private var createTitle = ""
    @State private var createSummary = ""
    @State private var createSeverity = "medium"
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var error = ""
    @State private var notice = ""
    @State private var loadEpoch = 0

    private var allRows: [CasesWorkspaceRow] {
        (monitoringCases.map(CasesWorkspaceRow.init) + (intelligencePage?.items ?? []).map(CasesWorkspaceRow.init) + moreIntelligenceCases.map(CasesWorkspaceRow.init))
            .reduce(into: [String: CasesWorkspaceRow]()) { $0[$1.id] = $1 }
            .values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visibleRows: [CasesWorkspaceRow] {
        allRows.filter { row in
            let active = !["resolved", "closed", "suppressed", "false_positive"].contains(row.status.lowercased())
            let statusMatches = status == "all" || (status == "active" ? active : row.status == status)
            let severityMatches = severity == "all" || row.severity.lowercased() == severity
            let sourceMatches = source == "all" || row.source.lowercased() == source
            let ownerMatches = owner == "all" || (owner == "unassigned" ? row.owner.isEmpty : row.owner == owner)
            let resolutionType = row.monitoringCase?.resolutionType ?? row.intelligenceCase?.raw["resolution"]?["type"]?.stringValue ?? ""
            let resolutionMatches = resolution == "all" || resolutionType == resolution
            let reviewMatches = review == "all" || review == "pending" && (row.monitoringCase?.needsHumanReview ?? false)
                || review == "confirmed" && (row.monitoringCase?.humanReviewed ?? false)
            let searchMatches = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || [row.id, row.title, row.summary, row.owner, row.source].joined(separator: " ").localizedCaseInsensitiveContains(search)
            return statusMatches && severityMatches && sourceMatches && ownerMatches && resolutionMatches && reviewMatches && searchMatches
        }
    }

    private var routeOrganizationID: String? {
        model.nativeCaseHandoffContext?.organizationID ?? model.selectedNativeDashboardQuery["organizationId"]
            ?? model.selectedNativeDashboardQuery["org"]
    }

    private var mergeableRows: [CasesWorkspaceRow] {
        let selected = allRows.filter { selectedForMerge.contains($0.id) }
        guard let anchor = selected.first?.monitoringCase else { return [] }
        return selected.compactMap { row in
            guard let item = row.monitoringCase, item.canManage, !item.automationId.isEmpty,
                  item.automationId == anchor.automationId, item.organizationId == anchor.organizationId else { return nil }
            return row
        }
    }

    var body: some View {
        if !initialCaseID.isEmpty {
            caseDetailRoute
        } else {
            workspace
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Cases", subtitle: routeOrganizationID ?? (model.selectedOrganizationID.isEmpty ? "Personal workspace" : model.selectedOrganizationID)) {
                HStack(spacing: 8) {
                    SearchFieldRow(placeholder: "Search cases", text: $search)
                    ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await load(reset: true) } }
                        .disabled(isLoading || isWriting)
                    ActionButton(title: "Create case", icon: "plus") { prepareCreate() }.disabled(isWriting)
                    if selectedForMerge.count >= 2 {
                        ActionButton(title: "Merge \(selectedForMerge.count)", icon: "arrow.triangle.merge") { prepareMerge() }
                            .disabled(mergeableRows.count < 2 || isWriting)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) { filterPickers; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { filterPickers }
                }
                HStack(spacing: 8) {
                    Text("\(visibleRows.count) shown · \(allRows.count) loaded")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                    if isLoading { ProgressView().controlSize(.small); Text("Loading cases…").font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
                    Spacer(minLength: 0)
                    if let warning = intelligencePage?.nextCursor, !warning.isEmpty { Text("More intelligence cases available") .font(.system(size: 10)).foregroundStyle(theme.textTertiary) }
                }
                if !error.isEmpty { NativeNotice(message: error, title: "Cases unavailable", tone: .error) }
                if !notice.isEmpty { NativeNotice(message: notice, tone: .success) }
            }

            if visibleRows.isEmpty && !isLoading {
                NativeEmptyState(title: error.isEmpty ? (allRows.isEmpty ? "No cases yet" : "No matching cases") : "Cases could not be loaded",
                                 message: error.isEmpty ? (allRows.isEmpty ? "Cases from monitoring and threat intelligence will appear here." : "Change the filters or search text.") : "Refresh to try again.")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleRows) { row in caseRow(row) }
                }
            }
            if cursor != nil {
                HStack { Spacer(); ActionButton(title: isLoading ? "Loading…" : "Load more cases", icon: "arrow.down") { Task { await load(reset: false) } }.disabled(isLoading || isWriting); Spacer() }
            }
        }
        .task { await load(reset: true) }
        .onChange(of: model.selectedOrganizationID) { _, _ in Task { await load(reset: true) } }
        .confirmationDialog("Merge monitoring cases?", isPresented: $pendingMerge, titleVisibility: .visible) {
            ForEach(mergeableRows) { row in
                Button("Merge into \(row.title)", role: .destructive) {
                    mergeTarget = row.id
                    Task { await mergeCases(targetID: row.id) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose the target record. The other selected monitoring cases will be merged into it.")
        }
        .sheet(isPresented: $pendingCreate) { createCaseSheet }
    }

    @ViewBuilder private var filterPickers: some View {
        Picker("Status", selection: $status) {
            Text("Active").tag("active"); Text("All statuses").tag("all")
            ForEach(["open", "in_progress", "escalated", "resolved", "closed", "suppressed", "false_positive"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
        }.frame(maxWidth: 175)
        Picker("Severity", selection: $severity) {
            Text("All severity").tag("all")
            ForEach(["critical", "high", "medium", "low"], id: \.self) { Text($0.capitalized).tag($0) }
        }.frame(maxWidth: 150)
        Picker("Source", selection: $source) {
            Text("All sources").tag("all")
            ForEach(["monitoring", "security", "intelligence", "manual"], id: \.self) { Text($0.capitalized).tag($0) }
        }.frame(maxWidth: 155)
        Picker("Owner", selection: $owner) {
            Text("All owners").tag("all"); Text("Unassigned").tag("unassigned")
            ForEach(Array(Set(allRows.map(\.owner).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
        }.frame(maxWidth: 180)
        Picker("Resolved by", selection: $resolution) {
            Text("All resolvers").tag("all")
            ForEach(["human", "ai", "automation", "unknown"], id: \.self) { Text($0.capitalized).tag($0) }
        }.frame(maxWidth: 160)
        Picker("Human review", selection: $review) {
            Text("All review states").tag("all"); Text("Pending review").tag("pending"); Text("Confirmed").tag("confirmed")
        }.frame(maxWidth: 170)
    }

    private func caseRow(_ row: CasesWorkspaceRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if row.monitoringCase?.canManage == true {
                Toggle("Select \(row.title) for merge", isOn: Binding(
                    get: { selectedForMerge.contains(row.id) },
                    set: { value in if value { selectedForMerge.insert(row.id) } else { selectedForMerge.remove(row.id) } }
                )).labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                    Text(row.source.capitalized).font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textTertiary)
                    Spacer(minLength: 0)
                    Text(row.severity.isEmpty ? "Unrated" : row.severity.capitalized).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    Text(row.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                if !row.summary.isEmpty { Text(row.summary).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(3).textSelection(.enabled) }
                HStack(spacing: 10) {
                    Text(row.id).textSelection(.enabled)
                    Text(row.owner.isEmpty ? "Unassigned" : row.owner)
                    if !row.updatedAt.isEmpty { Text("Updated \(row.updatedAt)") }
                    Spacer(minLength: 0)
                    ActionButton(title: "Open", icon: "arrow.right") { open(row.id) }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(11).background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.divider, lineWidth: 1))
    }

    private var createCaseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create case").font(.system(size: 18, weight: .bold))
            Text(routeOrganizationID ?? (model.selectedOrganizationID.isEmpty ? "Personal workspace" : model.selectedOrganizationID))
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            TextField("Title", text: $createTitle).textFieldStyle(.roundedBorder)
            TextField("Description", text: $createSummary, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
            Picker("Severity", selection: $createSeverity) {
                ForEach(["low", "medium", "high", "critical"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            if !error.isEmpty { NativeNotice(message: error, title: "Could not create case", tone: .error) }
            HStack { Spacer(); Button("Cancel") { pendingCreate = false }.disabled(isWriting); ActionButton(title: isWriting ? "Creating…" : "Create case", icon: "plus") { Task { await createCase() } }.disabled(isWriting || createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(minWidth: 360, maxWidth: 540)
    }

    @ViewBuilder private var caseDetailRoute: some View {
        if initialCaseID.hasPrefix("HA-") || initialCaseID.hasPrefix("MON-") {
            MonitoringCasesNativePanel()
        } else {
            IntelligenceCasesNativePanel(initialCaseID: initialCaseID)
        }
    }

    @MainActor private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true; error = ""; notice = ""
        defer { isLoading = false }
        if reset { monitoringCases = []; intelligencePage = nil; moreIntelligenceCases = []; cursor = nil; selectedForMerge = [] }
        do {
            if let requested = routeOrganizationID, requested != model.selectedOrganizationID {
                guard await model.selectOrganizationFromDeepLink(requested), model.selectedOrganizationID == requested else {
                    throw CasesWorkspaceError.requestFailed(403)
                }
            }
            let settings = model.settings
            let client = try CasesWorkspaceClient(settings: settings)
            let intelligenceClient = try IntelligenceCasesClient(settings: settings)
            async let monitoringResult = client.loadMonitoringCases()
            async let intelligenceResult = intelligenceClient.load(cursor: reset ? nil : cursor)
            let (monitoring, intelligence) = try await (monitoringResult, intelligenceResult)
            guard settings == model.settings else { throw IntelligenceCasesError.scopeChanged }
            monitoringCases = monitoring
            if reset { intelligencePage = intelligence }
            else {
                moreIntelligenceCases += intelligence.items
            }
            cursor = intelligence.nextCursor
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ id: String) {
        model.openNativeDashboard(path: "/cases", label: "Case", detailID: id, query: model.selectedNativeDashboardQuery)
    }

    @MainActor private func prepareCreate() {
        createTitle = ""; createSummary = ""; createSeverity = "medium"; error = ""; pendingCreate = true
    }

    @MainActor private func createCase() async {
        guard !isWriting else { return }
        isWriting = true; error = ""
        defer { isWriting = false }
        do {
            let settings = model.settings
            let client = try CasesWorkspaceClient(settings: settings)
            let id = try await client.create(title: createTitle, summary: createSummary, severity: createSeverity,
                                             idempotencyKey: UUID().uuidString.lowercased())
            guard settings == model.settings else { throw IntelligenceCasesError.scopeChanged }
            pendingCreate = false
            await load(reset: true)
            open(id)
        } catch let requestError { error = requestError.localizedDescription }
    }

    @MainActor private func prepareMerge() {
        let eligible = mergeableRows
        guard eligible.count >= 2 else { return }
        pendingMerge = true
    }

    @MainActor private func mergeCases(targetID: String) async {
        guard !isWriting else { return }
        let eligible = mergeableRows
        let sourceIDs = eligible.map(\.id).filter { $0 != targetID }
        guard eligible.contains(where: { $0.id == targetID }), !sourceIDs.isEmpty else {
            error = "Select monitoring cases from the same automation and organization before merging."
            return
        }
        isWriting = true; error = ""; notice = ""
        defer { isWriting = false }
        do {
            let settings = model.settings
            let client = try CasesWorkspaceClient(settings: settings)
            try await client.merge(targetID: targetID, sourceIDs: sourceIDs)
            guard settings == model.settings else { throw IntelligenceCasesError.scopeChanged }
            selectedForMerge = []
            notice = "Cases merged. The list has been refreshed."
            await load(reset: true)
        } catch let requestError { error = requestError.localizedDescription }
    }
}
