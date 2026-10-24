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
    let context: [String]
    let resolutionLabel: String?
    let needsHumanReview: Bool
    let humanReviewed: Bool
    let monitoringCase: MonitoringCase?
    let intelligenceCase: IntelligenceCaseRow?

    init(_ value: MonitoringCase) {
        id = value.id; title = value.title; summary = value.summary; status = value.status
        severity = value.severity; owner = value.assignedOwner; updatedAt = value.updatedAt
        source = "monitoring"
        context = [MonitoringCase.stringValue(value.resolution, key: "actor")].compactMap { $0 }.filter { !$0.isEmpty }
        needsHumanReview = value.needsHumanReview
        humanReviewed = value.humanReviewed
        if value.needsHumanReview { resolutionLabel = "Needs human review" }
        else if value.humanReviewed { resolutionLabel = "Human confirmed" }
        else if !value.resolutionType.isEmpty {
            resolutionLabel = value.resolutionType == "ai" ? "AI resolved" : value.resolutionType == "automation" ? "Automatically recovered" : "Resolved by \(MonitoringCase.stringValue(value.resolution, key: "actor") ?? "human")"
        } else { resolutionLabel = nil }
        monitoringCase = value; intelligenceCase = nil
    }

    init(_ value: IntelligenceCaseRow) {
        id = value.id; title = value.title; summary = value.summary; status = value.status
        severity = value.severity; owner = value.assignedOwner; updatedAt = value.updatedAt
        source = value.source.isEmpty ? "intelligence" : value.source
        context = [value.raw["actor"]?.stringValue, value.raw["victimName"]?.stringValue ?? value.raw["company"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
        let resolution = value.raw["resolution"]
        let resolutionType = resolution?["type"]?.stringValue ?? ""
        let confirmedAt = resolution?["confirmedAt"]
        let isConfirmed: Bool = if case .string(let timestamp)? = confirmedAt { !timestamp.isEmpty } else { false }
        needsHumanReview = ["ai", "automation"].contains(resolutionType) && !isConfirmed
        humanReviewed = ["ai", "automation"].contains(resolutionType) && isConfirmed
        if ["ai", "automation"].contains(resolutionType) {
            resolutionLabel = isConfirmed ? "Human confirmed" : "Needs human review"
        } else if !resolutionType.isEmpty {
            resolutionLabel = resolutionType == "ai" ? "AI resolved" : resolutionType == "automation" ? "Automatically recovered" : "Resolved by \(resolution?["actor"]?.stringValue.isEmpty == false ? resolution!["actor"]!.stringValue : "human")"
        } else { resolutionLabel = nil }
        monitoringCase = nil; intelligenceCase = value
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
    @State private var createIdempotencyKey = UUID().uuidString.lowercased()
    @State private var retryCreateAfterReview = false
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var error = ""
    @State private var monitoringSourceError = ""
    @State private var intelligenceSourceError = ""
    @State private var notice = ""
    @State private var loadEpoch = 0
    @State private var mutationReview = CasesWorkspaceMutationReview()
    @State private var confirmingMutationReview = false

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
            let reviewMatches = review == "all" || review == "pending" && row.needsHumanReview
                || review == "confirmed" && row.humanReviewed
            let searchMatches = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ([row.id, row.title, row.summary, row.owner, row.source] + row.context).joined(separator: " ").localizedCaseInsensitiveContains(search)
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
                    ActionButton(title: "Create case", icon: "plus") { prepareCreate() }.disabled(isWriting || mutationReview.isLocked)
                    if selectedForMerge.count >= 2 {
                        ActionButton(title: "Merge \(selectedForMerge.count)", icon: "arrow.triangle.merge") { prepareMerge() }
                            .disabled(mergeableRows.count < 2 || isWriting || mutationReview.isLocked)
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
                if !monitoringSourceError.isEmpty { NativeNotice(message: monitoringSourceError, title: "Monitoring cases unavailable", tone: .error) }
                if !intelligenceSourceError.isEmpty { NativeNotice(message: intelligenceSourceError, title: "Intelligence cases unavailable", tone: .error) }
                if let operation = mutationReview.operation {
                    NativeNotice(message: "\(operation) outcome is unconfirmed. Refresh both case sources, inspect the current records, and acknowledge your review before starting another change.", title: "Previous case change needs review", tone: .error)
                    HStack(spacing: 8) {
                        ActionButton(title: "Refresh current records", icon: "arrow.clockwise") {
                            Task { await load(reset: true, forMutationReview: true) }
                        }.disabled(isLoading || isWriting)
                        ActionButton(title: "Acknowledge after review", icon: "checkmark.shield") {
                            confirmingMutationReview = true
                        }.disabled(!mutationReview.canAcknowledge || isWriting)
                    }
                }
                if !notice.isEmpty { NativeNotice(message: notice, tone: .success) }
            }

            if visibleRows.isEmpty && !isLoading {
                let sourceUnavailable = !monitoringSourceError.isEmpty || !intelligenceSourceError.isEmpty
                NativeEmptyState(title: !error.isEmpty || sourceUnavailable && allRows.isEmpty ? "Cases could not be loaded" : (allRows.isEmpty ? "No cases yet" : "No matching cases"),
                                 message: !error.isEmpty || sourceUnavailable && allRows.isEmpty ? "No cases from the available sources can be displayed. Refresh to try again." : (allRows.isEmpty ? "Cases from monitoring and threat intelligence will appear here." : "Change the filters or search text."))
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
        .onChange(of: resolution) { _, value in if value != "all" { status = "all" } }
        .onChange(of: review) { _, value in if value != "all" { status = "all" } }
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
        .confirmationDialog("Acknowledge this case review?", isPresented: $confirmingMutationReview, titleVisibility: .visible) {
            Button("I reviewed both refreshed case sources", role: .destructive) {
                if mutationReview.acknowledge() { notice = "Review acknowledged. The earlier case change remains unconfirmed." }
            }
            Button("Keep case changes locked", role: .cancel) { }
        } message: {
            Text("The earlier change remains unconfirmed. Check the current cases and history before continuing.")
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
                )).labelsHidden().toggleStyle(.checkbox).padding(.top, 3).disabled(isWriting || mutationReview.isLocked)
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
                if !row.context.isEmpty { Text(row.context.joined(separator: " · ")).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(2).textSelection(.enabled) }
                if let resolutionLabel = row.resolutionLabel { Text(resolutionLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(2) }
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
            TextField("Title", text: $createTitle).textFieldStyle(.roundedBorder).disabled(isWriting || mutationReview.isLocked)
            TextField("Description", text: $createSummary, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(isWriting || mutationReview.isLocked)
            Picker("Severity", selection: $createSeverity) {
                ForEach(["low", "medium", "high", "critical"], id: \.self) { Text($0.capitalized).tag($0) }
            }.disabled(isWriting || mutationReview.isLocked)
            if !error.isEmpty { NativeNotice(message: error, title: "Could not create case", tone: .error) }
            HStack { Spacer(); Button("Cancel") { pendingCreate = false }.disabled(isWriting || mutationReview.isLocked); ActionButton(title: isWriting ? "Creating…" : mutationReview.isLocked ? "Review required" : "Create case", icon: "plus") { Task { await createCase() } }.disabled(isWriting || mutationReview.isLocked || createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(minWidth: 360, maxWidth: 540)
            .onChange(of: createTitle) { _, _ in if !isWriting && !mutationReview.isLocked { createIdempotencyKey = UUID().uuidString.lowercased() } }
            .onChange(of: createSummary) { _, _ in if !isWriting && !mutationReview.isLocked { createIdempotencyKey = UUID().uuidString.lowercased() } }
            .onChange(of: createSeverity) { _, _ in if !isWriting && !mutationReview.isLocked { createIdempotencyKey = UUID().uuidString.lowercased() } }
    }

    @ViewBuilder private var caseDetailRoute: some View {
        if initialCaseID.hasPrefix("HA-") || initialCaseID.hasPrefix("MON-") {
            MonitoringCasesNativePanel()
        } else {
            IntelligenceCasesNativePanel(initialCaseID: initialCaseID)
        }
    }

    @MainActor private func load(reset: Bool, forMutationReview: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true; error = ""; notice = ""
        if forMutationReview { mutationReview.recordRefresh(monitoringLoaded: false, intelligenceLoaded: false) }
        monitoringSourceError = ""; intelligenceSourceError = ""
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
            async let monitoringResult = monitoringOutcome(client)
            async let intelligenceResult = intelligenceOutcome(intelligenceClient, cursor: reset ? nil : cursor)
            let (monitoring, intelligence) = await (monitoringResult, intelligenceResult)
            guard settings == model.settings else { throw IntelligenceCasesError.scopeChanged }
            if monitoring.accessRejected || intelligence.accessRejected {
                monitoringCases = []; intelligencePage = nil; moreIntelligenceCases = []; cursor = nil
                monitoringSourceError = monitoring.accessRejected ? monitoring.error ?? "Monitoring case access could not be verified." : ""
                intelligenceSourceError = intelligence.accessRejected ? intelligence.error ?? "Intelligence case access could not be verified." : ""
                return
            }
            if forMutationReview {
                mutationReview.recordRefresh(monitoringLoaded: monitoring.value != nil, intelligenceLoaded: intelligence.value != nil)
            }
            if let monitoring = monitoring.value { monitoringCases = monitoring }
            else { monitoringSourceError = monitoring.error ?? "Monitoring cases are unavailable. Refresh to try again." }
            if let intelligence = intelligence.value {
                if reset { intelligencePage = intelligence }
                else {
                    moreIntelligenceCases += intelligence.items
                }
                cursor = intelligence.nextCursor
            } else {
                intelligenceSourceError = intelligence.error ?? "Intelligence cases are unavailable. Refresh to try again."
            }
            if monitoring.value == nil && intelligence.value == nil { error = "Neither case source could be loaded. Refresh to try again." }
        } catch { self.error = error.localizedDescription }
    }

    private func monitoringOutcome(_ client: CasesWorkspaceClient) async -> (value: [MonitoringCase]?, error: String?, accessRejected: Bool) {
        do { return (try await client.loadMonitoringCases(), nil, false) }
        catch let error as CasesWorkspaceError {
            let accessRejected = error == .requestFailed(401) || error == .requestFailed(403)
            return (nil, error.localizedDescription, accessRejected)
        } catch { return (nil, error.localizedDescription, false) }
    }

    private func intelligenceOutcome(_ client: IntelligenceCasesClient, cursor: String?) async -> (value: IntelligenceCasePage?, error: String?, accessRejected: Bool) {
        do { return (try await client.load(cursor: cursor), nil, false) }
        catch let error as IntelligenceCasesError {
            let accessRejected = error == .requestFailed(401) || error == .requestFailed(403)
            return (nil, error.localizedDescription, accessRejected)
        } catch { return (nil, error.localizedDescription, false) }
    }

    private func open(_ id: String) {
        model.openNativeDashboard(path: "/cases", label: "Case", detailID: id, query: model.selectedNativeDashboardQuery)
    }

    @MainActor private func prepareCreate() {
        if retryCreateAfterReview { retryCreateAfterReview = false }
        else { createTitle = ""; createSummary = ""; createSeverity = "medium"; createIdempotencyKey = UUID().uuidString.lowercased() }
        error = ""; pendingCreate = true
    }

    @MainActor private func createCase() async {
        guard !isWriting, !mutationReview.isLocked else { return }
        isWriting = true; error = ""
        defer { isWriting = false }
        do {
            let settings = model.settings
            let client = try CasesWorkspaceClient(settings: settings)
            let id = try await client.create(title: createTitle, summary: createSummary, severity: createSeverity,
                                             idempotencyKey: createIdempotencyKey)
            guard settings == model.settings else { throw IntelligenceCasesError.scopeChanged }
            pendingCreate = false
            retryCreateAfterReview = false
            await load(reset: true)
            open(id)
        } catch let requestError {
            error = requestError.localizedDescription
            if CasesWorkspaceMutationOutcome.needsReview(for: requestError) {
                mutationReview.requireReview(for: "Create case")
                retryCreateAfterReview = true
                pendingCreate = false
            }
        }
    }

    @MainActor private func prepareMerge() {
        let eligible = mergeableRows
        guard eligible.count >= 2 else { return }
        pendingMerge = true
    }

    @MainActor private func mergeCases(targetID: String) async {
        guard !isWriting, !mutationReview.isLocked else { return }
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
        } catch let requestError {
            error = requestError.localizedDescription
            if CasesWorkspaceMutationOutcome.needsReview(for: requestError) {
                mutationReview.requireReview(for: "Merge monitoring cases")
            }
        }
    }
}
