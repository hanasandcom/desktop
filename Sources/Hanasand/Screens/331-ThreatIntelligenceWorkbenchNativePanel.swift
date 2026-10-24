import SwiftUI

struct ThreatIntelligenceWorkbenchNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var findings: ThreatFindingPage?
    @State private var cases: IntelligenceCasePage?
    @State private var deliveries: ThreatDeliveryHistory?
    @State private var isLoading = false
    @State private var message = ""
    @State private var requestID = UUID()

    private var scopeKey: String {
        [model.settings.websiteBaseURL, model.userIDForRequests, model.selectedOrganizationID,
         model.hasHanasandAuth ? "signed-in" : "signed-out"].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Threat Intelligence Workbench", subtitle: subtitle) {
                HStack(spacing: 8) {
                    ActionButton(title: "Findings", icon: "exclamationmark.shield") {
                        model.openNativeDashboard(path: "/findings", label: "Findings")
                    }
                    ActionButton(title: "Intelligence cases", icon: "checkmark.square") {
                        model.openNativeDashboard(path: "/cases/intelligence", label: "Intelligence Cases")
                    }
                    ActionButton(title: "Delivery history", icon: "paperplane") {
                        model.openNativeDashboard(path: "/dashboard/delivery-history", label: "Delivery History")
                    }
                    ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") {
                        Task { await load() }
                    }.disabled(isLoading)
                }
                if !message.isEmpty {
                    Text(message).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.hasHanasandAuth {
                NativeEmptyState(title: "Sign in required", message: "Sign in to load findings and intelligence cases in this workspace.")
            } else if isLoading && findings == nil && cases == nil {
                NativeGroupPanel(title: "Loading workbench", subtitle: "Loading findings and cases for the current workspace") {
                    ProgressView().controlSize(.small)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    findingsSection
                    casesSection
                    deliverySection
                }
            }
        }
        .padding(16)
        .task(id: scopeKey) { await load() }
    }

    private var subtitle: String {
        model.selectedOrganizationID.isEmpty || model.selectedOrganizationID == "personal"
            ? "Personal workspace · alerts, case triage, and delivery readiness"
            : "Organization · \(model.selectedOrganizationID) · alerts, case triage, and delivery readiness"
    }

    @ViewBuilder private var findingsSection: some View {
        NativeGroupPanel(title: "Findings", subtitle: findings.map { "\($0.total) total alerts · \($0.alerts.count) loaded" } ?? "Unavailable") {
            if let findings {
                let open = findings.alerts.filter { $0.reviewState.lowercased() != "closed" && $0.reviewState.lowercased() != "resolved" }
                Text("\(open.count) loaded alerts need review").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                ForEach(open.prefix(3)) { alert in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                        Text("\(alert.severity.capitalized) · \(alert.reviewState.replacingOccurrences(of: "_", with: " ").capitalized)")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }
                }
                ActionButton(title: "Review findings", icon: "arrow.right") {
                    model.openNativeDashboard(path: "/findings", label: "Findings")
                }
            } else {
                Text("Findings could not be loaded.").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    @ViewBuilder private var casesSection: some View {
        NativeGroupPanel(title: "Intelligence cases", subtitle: cases.map { "\($0.total ?? $0.items.count) cases · \($0.items.count) loaded" } ?? "Unavailable") {
            if let cases {
                let active = cases.items.filter { !["resolved", "closed", "suppressed", "false_positive"].contains($0.status.lowercased()) }
                Text("\(active.count) loaded cases are active").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                ForEach(active.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                        Text("\(item.severity.capitalized) · \(item.status.replacingOccurrences(of: "_", with: " ").capitalized)")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }
                }
                ActionButton(title: "Triage intelligence cases", icon: "arrow.right") {
                    model.openNativeDashboard(path: "/cases/intelligence", label: "Intelligence Cases")
                }
            } else {
                Text("Intelligence cases could not be loaded.").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    @ViewBuilder private var deliverySection: some View {
        NativeGroupPanel(title: "Webhook delivery", subtitle: deliveries.map { "\($0.deliveries.count) delivery records" } ?? "Organization access required") {
            if let deliveries {
                let failed = deliveries.deliveries.filter { $0.status == .failed }.count
                Text("\(failed) failed · \(deliveries.deliveries.count - failed) other deliveries")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                if !deliveries.notice.isEmpty {
                    Text(deliveries.notice).font(.system(size: 10)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                ActionButton(title: "Review delivery history", icon: "arrow.right") {
                    model.openNativeDashboard(path: "/dashboard/delivery-history", label: "Delivery History")
                }
            } else {
                Text("Select an organization with delivery access to review webhook status.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor private func load() async {
        guard !isLoading, model.hasHanasandAuth else { return }
        let current = UUID()
        requestID = current
        let settings = model.settings
        isLoading = true
        message = ""
        defer { if requestID == current { isLoading = false } }

        async let findingsResult = model.loadThreatFindings()
        async let casesResult = try? IntelligenceCasesClient(settings: settings).load()
        let (loadedFindings, loadedCases) = await (try? findingsResult, casesResult)
        guard requestID == current, model.settings == settings, !Task.isCancelled else { return }
        findings = loadedFindings
        cases = loadedCases

        if !settings.selectedOrganizationID.isEmpty, settings.selectedOrganizationID != "personal", settings.selectedOrganizationUserID == settings.userID {
            deliveries = try? await ThreatDeliveryHistoryClient(settings: settings).load()
        } else {
            deliveries = nil
        }
        guard requestID == current, model.settings == settings, !Task.isCancelled else { return }
        if findings == nil && cases == nil {
            message = "Findings and cases could not be loaded. Check organization access and refresh."
        } else {
            message = "Showing read-only triage summaries for the selected workspace."
        }
    }
}
