import SwiftUI

struct SandboxHistoryNativePanel: View {
    private enum QuotaLoadState: Equatable { case loading, ready, unavailable }

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var runs: [SandboxHistoryRun] = []
    @State private var nextOffset: Int?
    @State private var initialRunID: String?
    @State private var selectedRunID = ""
    @State private var isLoading = false
    @State private var isLoadingReport = false
    @State private var reportRequestID = UUID()
    @State private var error = ""
    @State private var selectedReport: SandboxHistoryReport?
    @State private var quota: SandboxHistoryQuota?
    @State private var quotaLoadState = QuotaLoadState.loading

    private var selectedRun: SandboxHistoryRun? { runs.first { $0.id == selectedRunID } }

    init(initialRunID: String? = nil) {
        _initialRunID = State(initialValue: initialRunID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Saved Sandbox runs", subtitle: "Owner-only run history and reports") {
                HStack(spacing: 10) {
                    Text("Saved runs and reports are loaded in the app. Selecting a run never opens its target.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") {
                        Task {
                            await refresh()
                            await refreshQuota()
                        }
                    }
                    .disabled(isLoading || !model.hasHanasandAuth)
                }
                if !error.isEmpty { NativeNotice(message: error) }
            }

            NativeGroupPanel(title: "Run limits", subtitle: "Current Sandbox usage") {
                HStack(alignment: .center, spacing: 10) {
                    Group {
                        switch quotaLoadState {
                        case .loading:
                            Text("Loading run limits…")
                        case .ready:
                            Text(quota?.summary ?? "Run limits unavailable")
                        case .unavailable:
                            Text(model.hasHanasandAuth ? "Run limits unavailable. Refresh to try again." : "Sign in to view run limits.")
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if quotaLoadState == .unavailable {
                        ActionButton(title: "Retry", icon: "arrow.clockwise") { Task { await refreshQuota() } }
                            .disabled(!model.hasHanasandAuth)
                    }
                }
                .accessibilityIdentifier("sandbox-quota-summary")
            }

            NativeGroupPanel(title: "Run history", subtitle: "Newest runs first") {
                if isLoading && runs.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading saved runs…") }
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                } else if runs.isEmpty {
                    NativeEmptyState(title: error.isEmpty ? "No saved runs" : "Run history unavailable",
                                     message: error.isEmpty ? "Saved Sandbox runs will appear here." : "Refresh to try again.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(runs) { run in runRow(run) }
                    }
                }

                if let selectedRun {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected run")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.text)
                        metadataLine("Target", value: selectedRun.displayTarget)
                        metadataLine("Status", value: selectedRun.status)
                        metadataLine("Started", value: selectedRun.startedAt)
                        metadataLine("Network", value: selectedRun.network)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let selectedReport {
                    NativeGroupPanel(title: "Saved report", subtitle: selectedReport.target) {
                        ForEach(Array(selectedReport.entries.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title.isEmpty ? entry.kind : entry.title)
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                                if !entry.url.isEmpty { Text(entry.url).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                                if !entry.detail.isEmpty { Text(entry.detail).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else if isLoadingReport {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading saved report…")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                if nextOffset != nil {
                    HStack {
                        Spacer()
                        ActionButton(title: isLoading ? "Loading…" : "Load more", icon: "chevron.down") {
                            Task { await loadMore() }
                        }
                        .disabled(isLoading)
                        Spacer()
                    }
                }
            }
        }
        .task {
            async let history: Void = refresh()
            async let limits: Void = refreshQuota()
            _ = await (history, limits)
        }
    }

    private func runRow(_ run: SandboxHistoryRun) -> some View {
        Button {
            if selectedRunID == run.id {
                selectedRunID = ""
                selectedReport = nil
                reportRequestID = UUID()
                isLoadingReport = false
            } else {
                selectedRunID = run.id
                selectedReport = nil
                Task { await loadReport(run) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedRunID == run.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(theme.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.displayTarget)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("\(run.status) · \(run.startedAt) · \(run.network)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !run.providerResults.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(run.providerResults) { result in
                                Text(result.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(providerColor(result.status))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(providerColor(result.status).opacity(0.12), in: Capsule())
                                    .accessibilityLabel("\(result.id): \(result.label) (\(result.status))")
                            }
                        }
                    }
                    Text("Run \(run.id)")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerColor(_ status: String) -> Color {
        switch status {
        case "suspicious", "blocked": theme.danger
        case "loading": theme.textTertiary
        default: theme.green
        }
    }

    @MainActor
    private func loadReport(_ run: SandboxHistoryRun) async {
        let requestID = UUID()
        reportRequestID = requestID
        isLoadingReport = true
        defer {
            if reportRequestID == requestID { isLoadingReport = false }
        }
        error = ""
        do {
            let report = try await makeReportClient().loadReport(resultID: run.resultID)
            guard reportRequestID == requestID, selectedRunID == run.id else { return }
            selectedReport = report
        } catch {
            guard reportRequestID == requestID, selectedRunID == run.id else { return }
            selectedReport = nil
            self.error = error.localizedDescription
        }
    }

    private func metadataLine(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try makeClient()
            var page = try await client.loadPage()
            var loadedRuns = page.runs
            if let requestedID = initialRunID, !requestedID.isEmpty {
                for _ in 0..<4 {
                    if loadedRuns.contains(where: { $0.id == requestedID || $0.resultID == requestedID }) { break }
                    guard let offset = page.nextOffset else { break }
                    page = try await client.loadPage(offset: offset)
                    let known = Set(loadedRuns.map(\.id))
                    loadedRuns.append(contentsOf: page.runs.filter { !known.contains($0.id) })
                }
            }
            runs = loadedRuns
            nextOffset = page.nextOffset
            error = ""
            if let requestedID = initialRunID, !requestedID.isEmpty {
                if let run = loadedRuns.first(where: { $0.id == requestedID || $0.resultID == requestedID }) {
                    selectedRunID = run.id
                    initialRunID = nil
                    await loadReport(run)
                } else {
                    error = "The requested saved run was not found in the latest 250 records. Refresh the history and try again."
                }
            }
            if !runs.contains(where: { $0.id == selectedRunID }) {
                selectedRunID = ""
                selectedReport = nil
                reportRequestID = UUID()
                isLoadingReport = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, let offset = nextOffset else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await makeClient().loadPage(offset: offset)
            let known = Set(runs.map(\.id))
            runs.append(contentsOf: page.runs.filter { !known.contains($0.id) })
            nextOffset = page.nextOffset
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeClient() throws -> SandboxHistoryClient {
        try SandboxHistoryClient(
            userID: model.settings.userID,
            token: model.settings.authToken,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }

    private func makeReportClient() throws -> SandboxHistoryReportClient {
        try SandboxHistoryReportClient(
            userID: model.settings.userID,
            token: model.settings.authToken,
            impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.settings.impersonatingUserID
        )
    }

    @MainActor
    private func refreshQuota() async {
        guard model.hasHanasandAuth else {
            quota = nil
            quotaLoadState = .unavailable
            return
        }
        quotaLoadState = .loading
        do {
            let loaded = try await makeClient().loadQuota()
            quota = loaded
            quotaLoadState = .ready
        } catch {
            quota = nil
            quotaLoadState = .unavailable
        }
    }
}
