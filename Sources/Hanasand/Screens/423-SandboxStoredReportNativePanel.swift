import SwiftUI
import AppKit

struct SandboxStoredReportNativePanel: View {
    let resultID: String?
    let runID: String?
    let reportToken: String?
    let initialSelectedRunID: String?

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var report: SandboxStoredReport?
    @State private var selectedRunID = ""
    @State private var message = ""
    @State private var isLoading = false

    init(resultID: String? = nil, runID: String? = nil, reportToken: String? = nil, selectedRunID: String? = nil) {
        self.resultID = resultID
        self.runID = runID
        self.reportToken = reportToken
        self.initialSelectedRunID = selectedRunID
        _selectedRunID = State(initialValue: selectedRunID ?? "")
    }

    private var routeKey: String { [resultID ?? "", runID ?? "", reportToken ?? "", initialSelectedRunID ?? "", selectedRunID].joined(separator: "|") }

    var body: some View {
        NativeGroupPanel(title: "Sandbox report", subtitle: report?.target ?? "Saved browser evidence") {
            HStack(spacing: 10) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(message.isEmpty ? "Review the saved browser result and evidence." : message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActionButton(title: isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading)
            }
            if let report {
                reportHeader(report)
                HStack {
                    ActionButton(title: "Export JSON", icon: "square.and.arrow.down") {
                        exportReport(report)
                    }
                    .disabled(report.exportData.isEmpty)
                }
                if report.availableRuns.count > 1 {
                    HStack {
                        Text("Run")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Picker("Run", selection: $selectedRunID) {
                            ForEach(report.availableRuns) { run in
                                Text([run.startedAt, run.status].filter { !$0.isEmpty }.joined(separator: " · ")).tag(run.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 420)
                    }
                    .onChange(of: selectedRunID) { _, _ in Task { await load() } }
                }
                if !report.summary.isEmpty {
                    reportSection("Summary") {
                        Text(report.summary).font(.system(size: 12)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    }
                }
                if !report.indicators.isEmpty {
                    reportSection("Indicators") { bulletList(report.indicators) }
                }
                if !report.recommendedActions.isEmpty {
                    reportSection("Recommended actions") { bulletList(report.recommendedActions) }
                }
                if !report.threatAssociations.isEmpty {
                    reportSection("Threat context") { lineList(report.threatAssociations) }
                }
                if !report.timeline.isEmpty {
                    reportSection("URL timeline") { lineList(report.timeline) }
                }
                if !report.providers.isEmpty {
                    reportSection("Providers") { lineList(report.providers) }
                }
                if !report.evidence.isEmpty {
                    reportSection("Evidence · \(report.evidence.count)") { lineList(report.evidence) }
                }
                if !report.captures.isEmpty {
                    reportSection("Screenshots and captures · \(report.captures.count)") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(report.captures) { capture in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(capture.title.isEmpty ? "Capture" : capture.title)
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                                    if !capture.url.isEmpty { Text(capture.url).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
                                    if let image = image(for: capture.imageDataURL) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                                    }
                                    if !capture.textExcerpt.isEmpty { expandableText("Page text", capture.textExcerpt) }
                                    if !capture.sourceCode.isEmpty { expandableText("Source code", capture.sourceCode) }
                                    Text([capture.capturedAt, capture.reason].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                if capture.id != report.captures.last?.id { Divider() }
                            }
                        }
                    }
                }
                if !report.networkEvidence.isEmpty {
                    reportSection("Network evidence · \(report.networkEvidence.count)") { lineList(report.networkEvidence) }
                }
                if !report.scriptArtifacts.isEmpty {
                    reportSection("Script artifacts") { lineList(report.scriptArtifacts) }
                }
                if !report.consoleEvents.isEmpty {
                    reportSection("Console logs") { bulletList(report.consoleEvents) }
                }
                if report.summary.isEmpty && report.indicators.isEmpty && report.recommendedActions.isEmpty
                    && report.threatAssociations.isEmpty && report.timeline.isEmpty && report.providers.isEmpty && report.evidence.isEmpty
                    && report.captures.isEmpty && report.networkEvidence.isEmpty && report.scriptArtifacts.isEmpty
                    && report.consoleEvents.isEmpty {
                    NativeEmptyState(title: "No report evidence", message: "This saved run does not contain report details.")
                }
            } else if !isLoading && message.isEmpty {
                NativeEmptyState(title: "No report loaded", message: "Refresh to retrieve the saved Sandbox report.")
            }
        }
        .task(id: routeKey) { await load() }
    }

    private func reportHeader(_ report: SandboxStoredReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FeatureCard(title: "Verdict", value: report.verdict.isEmpty ? "Not recorded" : report.verdict, icon: "shield.lefthalf.filled")
                FeatureCard(title: "Run", value: report.id, icon: "clock")
                if !report.status.isEmpty { FeatureCard(title: "Status", value: report.status, icon: "checkmark.circle") }
            }
            labeledValue("Target", report.target)
            if report.finalURL != report.target { labeledValue("Final URL", report.finalURL) }
            if !report.exportedAt.isEmpty { labeledValue("Saved", report.exportedAt) }
        }
    }

    @MainActor
    private func exportReport(_ report: SandboxStoredReport) {
        guard !report.exportData.isEmpty else { return }
        let panel = NSSavePanel()
        let fileID = report.id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil ? report.id : "report"
        panel.nameFieldStringValue = "browser-sandbox-\(fileID).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.exportData.write(to: url, options: .atomic)
                Task { @MainActor in message = "Report exported to \(url.lastPathComponent)." }
            } catch {
                Task { @MainActor in message = "Could not export the report: \(error.localizedDescription)" }
            }
        }
    }

    private func reportSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NativeGroupPanel(title: title, subtitle: "") { content() }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary).frame(width: 76, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "circle.fill").font(.system(size: 4)).padding(.top, 6).foregroundStyle(theme.accent)
                    Text(item).font(.system(size: 11)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                }
            }
        }
    }

    private func lineList(_ items: [SandboxStoredReportLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    if !item.title.isEmpty { Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled) }
                    if !item.detail.isEmpty { Text(item.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                if item.id != items.last?.id { Divider() }
            }
        }
    }

    private func expandableText(_ title: String, _ value: String) -> some View {
        DisclosureGroup(title) {
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textSecondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
    }

    private func image(for dataURL: String) -> NSImage? {
        guard let separator = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...]), options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        isLoading = true
        message = "Loading report…"
        defer { isLoading = false }
        do {
            let client = try SandboxStoredReportClient(
                userID: model.userIDForRequests,
                authToken: model.authTokenForRequests,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID
            )
            let selectedRun = selectedRunID.isEmpty ? initialSelectedRunID : selectedRunID
            let loaded = try await client.load(resultID: resultID, runID: runID, reportToken: reportToken,
                                               selectedRunID: selectedRun?.isEmpty == true ? nil : selectedRun)
            report = loaded
            if selectedRunID.isEmpty, loaded.availableRuns.contains(where: { $0.id == loaded.id }) {
                selectedRunID = loaded.id
            }
            message = "Report loaded."
        } catch {
            report = nil
            message = (error as? LocalizedError)?.errorDescription ?? "The Sandbox report could not be loaded."
        }
    }
}
