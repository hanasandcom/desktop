import SwiftUI

private enum PendingDeliveryAction {
    case test, send, retry(ThreatDeliveryHistory.Attempt)
    var title: String {
        switch self { case .test: "Test delivery?"; case .send: "Send finding?"; case .retry: "Retry delivery?" }
    }
    var message: String {
        switch self {
        case .test: "This records a dry-run test without sending to an external destination."
        case .send: "This sends the selected finding to its configured destinations."
        case .retry: "This retries the failed attempt and may send its message to a configured destination."
        }
    }
}

struct ThreatDeliveryHistoryNativePanel: View {
    var initialOrganizationID: String? = nil
    private let statusFilters: [ThreatDeliveryStatus] = [.delivered, .failed, .dryRun, .skipped]
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var history: ThreatDeliveryHistory?
    @State private var status = "Select an organization to review delivery history."
    @State private var search = ""
    @State private var findingSearch = ""
    @State private var selectedStatus: ThreatDeliveryStatus?
    @State private var reviewOnly = false
    @State private var selectedFindingID = ""
    @State private var findingPage = 0
    @State private var historyPage = 0
    @State private var isLoading = false
    @State private var reviewState = ThreatDeliveryReviewState()
    @State private var notice = ""
    @State private var pendingAction: PendingDeliveryAction?
    @State private var loadID = UUID()
    private var isWriting: Bool { reviewState.isWriting }
    private var requiresRefresh: Bool { reviewState.requiresRefresh }

    private var filteredSelectedAttempts: [ThreatDeliveryHistory.Attempt] {
        selectedAttempts.filter { attempt in
            (selectedStatus == nil || attempt.status == selectedStatus) && searchPartsMatch(attempt)
        }
    }
    private var selectedFinding: ThreatDeliveryHistory.Finding? { history?.selectedFinding(selectedFindingID) }
    private var selectedAttempts: [ThreatDeliveryHistory.Attempt] { history?.attempts(for: selectedFindingID) ?? [] }
    private var filteredFindings: [ThreatDeliveryHistory.Finding] {
        (history?.findings ?? []).filter { finding in
            (!reviewOnly || !["resolved", "closed", "false_positive", "suppressed"].contains(finding.reviewState.lowercased()) && finding.deliveryState != "muted")
                && [finding.title, finding.actor, finding.matchedTerm].contains { $0.localizedCaseInsensitiveContains(findingSearch) }
        }
    }
    private var findingPages: Int { max(1, (filteredFindings.count + 19) / 20) }
    private var historyPages: Int { max(1, (selectedAttempts.count + 9) / 10) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search finding ID, delivery ID, or event", text: $search)
                    .frame(minWidth: 0, maxWidth: .infinity)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(isLoading || isWriting)
            }

            NativeGroupPanel(title: "Delivery history", subtitle: "Organization webhook and Discord attempts · latest 100") {
                Text("Review delivery attempts, select a finding, and run guarded test, send, or retry actions.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let history, let destinationRoute = ThreatDeliveryDestinationsRoute.make(organizationID: history.organizationID) {
                    ActionButton(title: "Manage destinations", icon: "point.3.connected.trianglepath.dotted") {
                        model.openNativeDashboard(path: destinationRoute.path, label: "Integrations", query: destinationRoute.query)
                    }
                    .disabled(isWriting)
                }
                if !status.isEmpty && history == nil {
                    NativeNotice(message: status)
                }
                if !notice.isEmpty { NativeNotice(message: notice) }
                if requiresRefresh {
                    NativeNotice(message: "Refresh and review the latest history before another action. The previous request may already have been recorded.")
                }
                if isLoading { ProgressView(status).frame(maxWidth: .infinity, alignment: .leading) }
                if let history {
                    if !history.notice.isEmpty { Text(history.notice).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary) }
                    findingPicker(history)
                    attemptHistory(history)
                } else if !isLoading {
                    NativeEmptyState(title: "Delivery history unavailable", message: status)
                }
            }
        }
        .confirmationDialog(pendingAction?.title ?? "Confirm delivery action", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button(actionConfirmationLabel, role: pendingAction.map { if case .send = $0 { return .destructive }; return .none } ?? .none) {
                let action = pendingAction
                pendingAction = nil
                Task { await perform(action) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction?.message ?? "") }
        .task(id: scopeIdentity) { await refresh() }
    }

    @ViewBuilder private func findingPicker(_ page: ThreatDeliveryHistory) -> some View {
        HStack(spacing: 8) {
            FilterChip(title: "All retained attempts", active: selectedFindingID.isEmpty) { selectFinding("") }
            FilterChip(title: "Choose finding · \(page.findings.count)", active: !selectedFindingID.isEmpty) { findingSearch = "" }
        }
        if !page.findings.isEmpty {
            SearchFieldRow(placeholder: "Search findings", text: $findingSearch)
                .onChange(of: findingSearch) { _, _ in findingPage = 0 }
            HStack(spacing: 8) {
                FilterChip(title: "All findings", active: !reviewOnly) { reviewOnly = false; findingPage = 0 }
                FilterChip(title: "Needs review", active: reviewOnly) { reviewOnly = true; findingPage = 0 }
            }
            if !filteredFindings.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(filteredFindings.dropFirst(findingPage * 20).prefix(20))) { finding in findingButton(finding) }
                }
                HStack(spacing: 8) {
                    ActionButton(title: "Previous findings", icon: "chevron.left") { findingPage = max(0, findingPage - 1) }.disabled(findingPage == 0)
                    Text("Page \(min(findingPage + 1, findingPages)) of \(findingPages)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                    ActionButton(title: "Next findings", icon: "chevron.right") { findingPage = min(findingPages - 1, findingPage + 1) }.disabled(findingPage + 1 >= findingPages)
                }
            } else { Text("No findings match this view.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
        }
        Text("\(page.findings.count) loaded findings · \(page.deliveries.count) retained attempts (latest 100 maximum)")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
    }

    @ViewBuilder private func attemptHistory(_ page: ThreatDeliveryHistory) -> some View {
        let attempts = filteredSelectedAttempts
        let successes = attempts.filter { $0.status == .delivered && !$0.dryRun }
        let failures = attempts.filter { $0.status == .failed }
        NativeGroupPanel(title: selectedFinding?.title ?? "All retained attempts", subtitle: selectedFinding.map { "\($0.actor.isEmpty ? "Actor not recorded" : $0.actor) · \($0.reviewState.isEmpty ? "Review state not recorded" : $0.reviewState)" } ?? "Latest attempts across this organization, including findings no longer listed.") {
            Text("Last attempt: \(attempts.first?.statusLabel ?? "No delivery yet") · Last success: \(successes.first?.displayDate ?? "Not recorded") · Needs review: \(failures.first?.displayDate ?? "No failed attempt")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let finding = selectedFinding {
                HStack(spacing: 8) {
                    ActionButton(title: "Test delivery", icon: "checkmark.shield") { pendingAction = .test }
                        .disabled(isLoading || isWriting || requiresRefresh || !page.canTest)
                    ActionButton(title: "Send finding", icon: "paperplane") { pendingAction = .send }
                        .disabled(isLoading || isWriting || requiresRefresh || !page.canSend)
                    if !finding.caseID.isEmpty {
                        ActionButton(title: "Open case", icon: "arrow.up.right.square") { openCase(finding.caseID, organizationID: finding.organizationID) }
                            .disabled(isWriting)
                    }
                }
            }
        }
        if attempts.isEmpty { Text(selectedFinding == nil ? "No delivery attempts available." : "No delivery attempt yet for this finding.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
        if !attempts.isEmpty {
            ForEach(Array(attempts.dropFirst(historyPage * 10).prefix(10))) { attempt in attemptCard(attempt, page: page) }
            HStack(spacing: 8) {
                ActionButton(title: "Previous", icon: "chevron.left") { historyPage = max(0, historyPage - 1) }.disabled(historyPage == 0)
                Text("Page \(historyPage + 1) of \(historyPages)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                ActionButton(title: "Next", icon: "chevron.right") { historyPage = min(historyPages - 1, historyPage + 1) }.disabled(historyPage + 1 >= historyPages)
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All · \(selectedAttempts.count)", active: selectedStatus == nil) { selectedStatus = nil; historyPage = 0 }
                ForEach(statusFilters, id: \.rawValue) { value in
                    FilterChip(title: "\(value.statusLabel) · \(selectedAttempts.filter { $0.status == value }.count)", active: selectedStatus == value) { selectedStatus = value; historyPage = 0 }
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        Text("Showing \(attempts.count) matching attempts")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
    }

    private func attemptCard(_ attempt: ThreatDeliveryHistory.Attempt, page: ThreatDeliveryHistory) -> some View {
        NativeGroupPanel(title: attempt.statusLabel, subtitle: attempt.displayDate) {
            HStack(spacing: 8) {
                Label(attempt.dryRun ? "Dry run" : attempt.eventType.isEmpty ? "Delivery event" : attempt.eventType,
                      systemImage: attempt.dryRun ? "checkmark.shield" : "paperplane")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if let attemptCount = attempt.attemptCount {
                    Text("\(attemptCount) \(attemptCount == 1 ? "attempt" : "attempts")")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
            }
            metadata(label: "Finding", value: compactID(attempt.alertId))
            metadata(label: "Delivery", value: compactID(attempt.id))
            if page.canRetry(attempt) {
                ActionButton(title: "Retry", icon: "arrow.clockwise") { pendingAction = .retry(attempt) }
                    .disabled(isLoading || isWriting || requiresRefresh)
            }
        }
    }

    private var actionConfirmationLabel: String {
        switch pendingAction { case .test: "Run dry-run test"; case .send: "Send finding"; case .retry: "Retry delivery"; case nil: "Confirm" }
    }
    private var scopeIdentity: ThreatDeliveryHistoryScopeIdentity {
        ThreatDeliveryHistoryScopeIdentity(initialOrganizationID: initialOrganizationID, settings: model.settings)
    }
    private func refresh() async {
        if let initialOrganizationID, !initialOrganizationID.isEmpty,
           initialOrganizationID != model.settings.selectedOrganizationID {
            let didSelectOrganization = await model.selectOrganizationFromDeepLink(initialOrganizationID)
            guard !Task.isCancelled else { return }
            guard didSelectOrganization else {
                history = nil
                status = model.organizationDirectoryError ?? "This delivery link belongs to an organization without a verified active membership."
                return
            }
        }
        let current = UUID(); loadID = current; history = nil; findingPage = 0; historyPage = 0; isLoading = true
        let requestedSettings = model.settings
        defer { if loadID == current { isLoading = false } }
        do {
            let result = try await ThreatDeliveryHistoryClient(settings: requestedSettings).load()
            guard !Task.isCancelled, loadID == current, model.settings == requestedSettings,
                  model.settings.selectedOrganizationID == result.organizationID,
                  model.settings.selectedOrganizationUserID == model.settings.userID else { return }
            history = result
            if !selectedFindingID.isEmpty && result.selectedFinding(selectedFindingID) == nil { selectedFindingID = "" }
            reviewState.refreshSucceeded()
            status = result.deliveries.isEmpty ? "No retained delivery attempts." : "Loaded \(result.deliveries.count) delivery attempts."
        } catch {
            guard !Task.isCancelled, loadID == current else { return }
            history = nil
            status = (error as? LocalizedError)?.errorDescription ?? "Delivery history could not be loaded. Refresh to try again."
        }
    }
    private func perform(_ action: PendingDeliveryAction?) async {
        guard let action, let page = history, reviewState.beginWrite() else { return }
        notice = ""
        defer { reviewState.finishWrite() }
        do {
            let receipts: [ThreatDeliveryHistory.Attempt]
            let confirmedSettings = model.settings
            let client = try ThreatDeliveryHistoryClient(settings: confirmedSettings)
            let scopeIsCurrent: @MainActor () -> Bool = {
                ThreatDeliveryHistoryClient.sameWriteScope(confirmedSettings, model.settings)
            }
            switch action {
            case .test: guard let selectedFinding else { throw ThreatDeliveryHistoryError.actionUnavailable }; receipts = try await client.perform(.test, finding: selectedFinding, scopeIsCurrent: scopeIsCurrent)
            case .send: guard let selectedFinding else { throw ThreatDeliveryHistoryError.actionUnavailable }; receipts = try await client.perform(.send, finding: selectedFinding, scopeIsCurrent: scopeIsCurrent)
            case .retry(let attempt): receipts = try await client.perform(.retry, attempt: attempt, scopeIsCurrent: scopeIsCurrent)
            }
            guard model.settings.selectedOrganizationID == page.organizationID else { throw ThreatDeliveryHistoryError.uncertainResult }
            notice = receipts.map { "\($0.statusLabel) · \($0.id)" }.joined(separator: "\n")
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? ThreatDeliveryHistoryError.uncertainResult.localizedDescription
        }
    }
    private func selectFinding(_ id: String) { selectedFindingID = id; historyPage = 0; notice = "" }
    private func findingButton(_ finding: ThreatDeliveryHistory.Finding) -> some View {
        let title = finding.title
        let subtitleParts = [finding.actor, finding.reviewState].filter { !$0.isEmpty }
        let subtitle = subtitleParts.joined(separator: " · ")
        let active = selectedFindingID == finding.id
        return Button { selectFinding(finding.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(active ? theme.accent.opacity(0.16) : theme.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(isWriting || requiresRefresh)
    }
    private func openCase(_ id: String, organizationID: String) {
        guard id.range(of: "^(HA|MON)-[1-9][0-9]*$", options: .regularExpression) != nil else { return }
        model.selectedDashboardPath = "/cases"
        model.selectedDashboardTitle = "Monitoring Cases"
        model.selectedSection = .dashboard
        model.selectedMonitoringCase = nil
        Task {
            await model.loadMonitoringCases()
            await model.loadMonitoringCaseDetail(id: id)
            guard model.selectedMonitoringCase?.organizationId == organizationID else {
                model.selectedMonitoringCase = nil
                model.nativeDashboardStatus = "Could not open case: it is not available in the selected organization."
                return
            }
        }
    }
    private func count(_ value: ThreatDeliveryStatus) -> Int { history?.deliveries.filter { $0.status == value }.count ?? 0 }
    private func searchPartsMatch(_ attempt: ThreatDeliveryHistory.Attempt) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [attempt.alertId, attempt.id, attempt.eventType, attempt.statusLabel].contains { $0.localizedCaseInsensitiveContains(query) }
    }
    private func metadata(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(theme.text).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 11, weight: .medium, design: .monospaced))
    }
    private func compactID(_ value: String) -> String { value.count > 20 ? "…\(value.suffix(16))" : value }
}
