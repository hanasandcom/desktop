import SwiftUI

struct ThreatFindingsNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var page: ThreatFindingPage?
    @State private var cursor: String?
    @State private var priorCursors: [String?] = []
    @State private var query = ""
    @State private var needsReview = false
    @State private var localPage = 0
    @State private var selectedID = ""
    @State private var evidencePage = 0
    @State private var isLoading = false
    @State private var error = ""
    @State private var loadEpoch = 0

    private var workspaceKey: String {
        [model.settings.websiteBaseURL, model.userIDForRequests, model.selectedOrganizationID,
         model.hasHanasandAuth ? "signed-in" : "signed-out"].joined(separator: "|")
    }

    private var findings: [ThreatFinding] {
        (page?.alerts ?? []).filter { $0.contains(query) && (!needsReview || $0.needsReview) }
            .sorted { (Date.ISO8601($0.observedAt) ?? .distantPast) > (Date.ISO8601($1.observedAt) ?? .distantPast) }
    }
    private var visibleFindings: [ThreatFinding] {
        let pageIndex = min(localPage, max(0, (findings.count - 1) / 20))
        return Array(findings.dropFirst(pageIndex * 20).prefix(20))
    }
    private var currentLocalPage: Int { min(localPage, max(0, (findings.count - 1) / 20)) }
    private var selected: ThreatFinding? { findings.first { $0.id == selectedID } }
    private var selectedCaseURL: URL? {
        guard let selected else { return nil }
        return ThreatFindingCaseLink.url(
            siteBaseURL: model.settings.websiteBaseURL,
            caseID: selected.caseID,
            alertID: selected.id,
            organizationID: selected.organizationID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Findings", subtitle: model.selectedOrganizationID.isEmpty ? "Personal monitoring" : "Organization monitoring") {
                HStack(spacing: 8) {
                    SearchFieldRow(placeholder: "Company, domain, or actor", text: $query)
                        .onChange(of: query) { _, value in
                            if value.count > 120 { query = String(value.prefix(120)) }
                            localPage = 0
                        }
                    ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load(reset: true) } }
                        .disabled(isLoading)
                }
                HStack(spacing: 8) {
                    FilterChip(title: "All findings", active: !needsReview) { needsReview = false; localPage = 0 }
                    FilterChip(title: "Needs review", active: needsReview) { needsReview = true; localPage = 0 }
                }
                if let page {
                    Text("\(findings.count) match in \(page.alerts.count) loaded findings · \(page.total) server records before local filters")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                if isLoading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading findings…").font(.system(size: 11)).foregroundStyle(theme.textSecondary) } }
                if !error.isEmpty {
                    NativeNotice(message: error)
                    ActionButton(title: "Retry", icon: "arrow.clockwise") { Task { await load(reset: false) } }.disabled(isLoading)
                }
            }

            if let selected {
                detail(selected)
            } else if page != nil && findings.isEmpty && !isLoading {
                NativeEmptyState(title: page?.alerts.isEmpty == true ? "No recent findings" : "No matching findings",
                                 message: page?.alerts.isEmpty == true && page?.nextCursor != nil ? "Continue to the next server page to look for findings." : "Try a different search or review filter.")
            } else if page == nil && !isLoading && error.isEmpty {
                NativeEmptyState(title: model.hasHanasandAuth ? "Findings not loaded" : "Sign in required",
                                 message: model.hasHanasandAuth ? "Refresh to load source-backed findings for this workspace." : "Sign in to view Findings.")
            }

            if selected == nil, page != nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(visibleFindings) { item in
                        NativeGroupPanel(title: item.title, subtitle: "\(item.severity.isEmpty ? "Severity not recorded" : item.severity.capitalized) · \(item.reviewState.isEmpty ? "Review state not recorded" : item.reviewState.replacingOccurrences(of: "_", with: " ").capitalized)") {
                            Text("Matched \(item.matchedTerm)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
                            Text(item.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(item.observation) · \(item.observedAt.isEmpty ? "Time not recorded" : item.observedAt) · \(item.evidence.count) evidence records")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(2)
                            ActionButton(title: "Investigate", icon: "arrow.right") { selectedID = item.id; evidencePage = 0 }
                                .disabled(isLoading)
                        }
                    }
                }
                if findings.count > 20 {
                    HStack(spacing: 8) {
                        ActionButton(title: "Previous loaded results", icon: "chevron.left") { localPage = max(0, currentLocalPage - 1) }
                            .disabled(currentLocalPage == 0)
                        ActionButton(title: "Next loaded results", icon: "chevron.right") { localPage = min((findings.count - 1) / 20, currentLocalPage + 1) }
                            .disabled((currentLocalPage + 1) * 20 >= findings.count)
                        Text("\(currentLocalPage * 20 + 1)–\(min((currentLocalPage + 1) * 20, findings.count)) of \(findings.count) loaded matches")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                    }
                }
                if findings.isEmpty, let page, !page.alerts.isEmpty {
                    NativeEmptyState(title: "No loaded findings match", message: "Change the text or review filter to see other loaded results.")
                }
                if let page {
                    HStack(spacing: 8) {
                        ActionButton(title: "Previous server page", icon: "chevron.left") { Task { await previous() } }.disabled(isLoading || priorCursors.isEmpty)
                        Text("Page \(priorCursors.count + 1) · \(min(page.alerts.count, 50)) records").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                        ActionButton(title: "Next server page", icon: "chevron.right") { Task { await next() } }.disabled(isLoading || page.nextCursor == nil || priorCursors.count >= 200)
                    }
                    if priorCursors.count >= 200 { Text("Reached the 200-page browsing limit. Refresh to start again.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
                }
                if let organizationID = page?.organization?.id {
                    ActionButton(title: "Monitored actors", icon: "person.2") {
                        model.openNativeDashboard(path: "/ti/profiles", label: "Monitored actors", query: ["organizationId": organizationID])
                    }.disabled(isLoading)
                }
            }
        }
        .task { if page == nil && error.isEmpty { await load(reset: true) } }
        .onChange(of: workspaceKey) { _, _ in
            loadEpoch += 1; isLoading = false
            page = nil; cursor = nil; priorCursors = []; selectedID = ""; error = ""
            Task { await load(reset: true, force: true) }
        }
    }

    @ViewBuilder private func detail(_ item: ThreatFinding) -> some View {
        ActionButton(title: "Back to findings", icon: "chevron.left") { selectedID = "" }
        NativeGroupPanel(title: item.title, subtitle: "\(item.severity.isEmpty ? "Severity not recorded" : item.severity.capitalized) · \(item.reviewState.isEmpty ? "Review state not recorded" : item.reviewState.replacingOccurrences(of: "_", with: " ").capitalized)") {
            Text("Matched \(item.matchedTerm)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            Text(item.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            Text("\(item.observation) · \(item.observedAt.isEmpty ? "Time not recorded" : item.observedAt)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
            Text(item.recommendedAction.isEmpty ? "No recommended action was recorded." : item.recommendedAction)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            if !item.actor.isEmpty { Text("Actor: \(item.actor)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
            if !item.actor.isEmpty {
                ActionButton(title: "Search actor", icon: "magnifyingglass") {
                    var query = [String: String]()
                    if let organizationID = item.organizationID { query["organizationId"] = organizationID }
                    model.openNativeDashboard(path: "/ti/profiles", label: "Actor profile: \(item.actor)", detailID: item.actor, query: query)
                }
            }
            if let caseURL = selectedCaseURL {
                ActionButton(title: "Open case", icon: "arrow.up.right") {
                    model.openURL(caseURL.absoluteString, label: "Linked case")
                }
            } else {
                Text(item.caseID.isEmpty ? "No case yet" : "The linked case is not available for this workspace.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            }
            Text("Findings are source reports for analyst review. Severity and review labels describe recorded workflow state; they do not confirm attribution.")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
        }
        evidence(item.evidence)
    }

    @ViewBuilder private func evidence(_ items: [ThreatFinding.Evidence]) -> some View {
        NativeGroupPanel(title: "Supporting evidence", subtitle: items.isEmpty ? "No retained evidence attached" : "\(items.count) retained evidence records") {
            if items.isEmpty { Text("No retained evidence is attached to this finding.").font(.system(size: 12)).foregroundStyle(theme.textTertiary) }
            else {
                let slice = Array(items.enumerated()).dropFirst(evidencePage * 10).prefix(10)
                ForEach(Array(slice), id: \.element.id) { _, item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.sourceName).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        Text("Capture: \(item.captureMode.isEmpty ? "Not recorded" : item.captureMode.replacingOccurrences(of: "_", with: " ")) · Redaction: \(item.redactionState.isEmpty ? "Not recorded" : item.redactionState.replacingOccurrences(of: "_", with: " "))")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                        Text("Observed: \(item.observedAt.isEmpty ? "Not recorded" : item.observedAt) · Published: \(item.publishedAt.isEmpty ? "Not recorded" : item.publishedAt) · Collected: \(item.collectedAt.isEmpty ? "Not recorded" : item.collectedAt)")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                        Text(item.safeToShow ? item.excerpt : "The excerpt is restricted. Only evidence metadata is shown.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Capture: \(item.captureID.isEmpty ? "Not recorded" : item.captureID) · Content hash: \(item.contentHash.isEmpty ? "Not recorded" : item.contentHash)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                }
                if items.count > 10 {
                    HStack(spacing: 8) {
                        ActionButton(title: "Previous evidence", icon: "chevron.left") { evidencePage = max(0, evidencePage - 1) }.disabled(evidencePage == 0)
                        ActionButton(title: "Next evidence", icon: "chevron.right") { evidencePage += 1 }.disabled((evidencePage + 1) * 10 >= items.count)
                        Text("\(evidencePage * 10 + 1)–\(min((evidencePage + 1) * 10, items.count)) of \(items.count)").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
    }

    @MainActor private func load(reset: Bool, force: Bool = false) async {
        if isLoading && !force { return }
        loadEpoch += 1
        let requestedEpoch = loadEpoch
        let requestedWorkspace = workspaceKey
        if reset { cursor = nil; priorCursors = []; selectedID = ""; localPage = 0; page = nil }
        isLoading = true; error = ""
        defer { if loadEpoch == requestedEpoch { isLoading = false } }
        do {
            let response = try await model.loadThreatFindings(cursor: cursor)
            guard requestedEpoch == loadEpoch, requestedWorkspace == workspaceKey else { return }
            page = response
            if let cursor, response.nextCursor == cursor { throw ThreatFindingsError.invalidResponse }
        } catch {
            guard requestedEpoch == loadEpoch, requestedWorkspace == workspaceKey else { return }
            page = nil
            self.error = error.localizedDescription
        }
    }

    @MainActor private func next() async {
        guard let next = page?.nextCursor, !isLoading, priorCursors.count < 200 else { return }
        guard !priorCursors.contains(where: { $0 == next }) else { error = "The next page repeated an earlier cursor. Refresh to start again."; return }
        priorCursors.append(cursor); cursor = next; selectedID = ""; localPage = 0
        await load(reset: false)
    }

    @MainActor private func previous() async {
        guard !isLoading, let previous = priorCursors.popLast() else { return }
        cursor = previous; selectedID = ""; localPage = 0
        await load(reset: false)
    }
}

private extension Date {
    static func ISO8601(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
