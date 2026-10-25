import SwiftUI

struct ThreatIntelligenceOverviewMetrics {
    static func statusCounts(_ statuses: [String?]) -> [String: Int] {
        statuses.reduce(into: [String: Int]()) { counts, rawValue in
            let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            counts[value.isEmpty ? "not reported" : value, default: 0] += 1
        }
    }

    static func recordsWithMissingStages(_ items: [ThreatIntelligenceTimelinessSnapshot.Item]) -> Int {
        items.filter { !$0.missingStages.isEmpty }.count
    }

    static func recordsWithTimestampAnomalies(_ items: [ThreatIntelligenceTimelinessSnapshot.Item]) -> Int {
        items.filter { !$0.anomalies.isEmpty }.count
    }
}

struct ThreatIntelligenceOverviewNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme

    let onOpenRoute: (String) -> Void

    @State private var sources: ThreatIntelligenceOperationalSourcePage?
    @State private var runs: ThreatIntelligenceCollectionRunPage?
    @State private var captures: ThreatIntelligenceCapturePage?
    @State private var delivery: ThreatIntelligenceTimelinessSnapshot?
    @State private var sourceError = ""
    @State private var runError = ""
    @State private var captureError = ""
    @State private var deliveryError = ""
    @State private var isLoading = false
    @State private var requestID = UUID()
    @State private var loadedScopeKey: String?

    init(onOpenRoute: @escaping (String) -> Void = { _ in }) {
        self.onOpenRoute = onOpenRoute
    }

    private var scopeKey: String {
        let settings = model.settings
        return [
            settings.websiteBaseURL,
            settings.userID,
            String(settings.authToken.hashValue),
            settings.selectedOrganizationID,
            settings.impersonatingUserID,
            settings.impersonationToken.isEmpty ? "own-account" : "impersonating",
        ].joined(separator: "|")
    }

    var body: some View {
        FeatureWorkspace(title: "Threat Intelligence overview", subtitle: "Live source operations, collection activity, evidence captures, and delivery timing") {
            NativeGroupPanel(title: "Operations snapshot", subtitle: "Authenticated live data · read-only overview") {
                HStack(spacing: 8) {
                    ActionButton(title: isLoading ? "Refreshing…" : "Refresh overview", icon: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .disabled(isLoading)
                    if isLoading { ProgressView().controlSize(.small) }
                }
            }

            if isLoading && sources == nil && runs == nil && captures == nil && delivery == nil {
                NativeGroupPanel(title: "Loading operational data", subtitle: "Reading sources, runs, captures, and delivery timing") {
                    ProgressView().controlSize(.small)
                }
            }

            shortcutPanel
            sourcePanel
            runPanel
            capturePanel
            deliveryPanel
        }
        .task(id: scopeKey) { await refresh() }
    }

    private var shortcutPanel: some View {
        NativeGroupPanel(title: "Open an operations view", subtitle: "Continue into the native, focused workspace") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                ActionButton(title: "Manage sources", icon: "dot.radiowaves.left.and.right") { onOpenRoute("/dashboard/ti/sources") }
                ActionButton(title: "Review collection runs", icon: "clock.arrow.circlepath") { onOpenRoute("/dashboard/ti/runs") }
                ActionButton(title: "Browse captures", icon: "camera") { onOpenRoute("/dashboard/ti/captures") }
                ActionButton(title: "Open delivery timing", icon: "chart.bar.xaxis") { onOpenRoute("/dashboard/ti/timeliness") }
            }
        }
    }

    private var sourcePanel: some View {
        NativeGroupPanel(title: "Source health", subtitle: sourceSummary) {
            if !sourceError.isEmpty { NativeNotice(message: sourceError, title: "Source operations unavailable") }
            if let sources {
                if sources.rows.isEmpty {
                    NativeEmptyState(title: sources.total == 0 ? "No sources reported" : "No sources on this page", message: "The source operations API returned no rows for the current first page.")
                } else {
                    let states = ThreatIntelligenceOverviewMetrics.statusCounts(sources.rows.map { $0.health?.state })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(states.keys.sorted(), id: \.self) { state in
                            metric(label: "Health · \(state)", value: String(states[state] ?? 0))
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(sources.rows.prefix(6))) { source in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(theme.accent)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name ?? "Unnamed source")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    Text([source.family, source.lifecycleStatus, source.health?.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    if let failure = source.health?.lastFailureReason, !failure.isEmpty {
                                        Text(failure).font(.system(size: 10)).foregroundStyle(theme.danger).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 0)
                                ActionButton(title: "Open sources", icon: "arrow.up.right") { onOpenRoute("/dashboard/ti/sources") }
                            }
                            .padding(.vertical, 6)
                            if source.id != sources.rows.prefix(6).last?.id { Divider() }
                        }
                    }
                }
            } else if !isLoading && sourceError.isEmpty {
                NativeEmptyState(title: "Source data has not loaded", message: "Refresh this overview to request source health.")
            }
        }
    }

    private var runPanel: some View {
        NativeGroupPanel(title: "Collection activity", subtitle: runSummary) {
            if !runError.isEmpty { NativeNotice(message: runError, title: "Collection runs unavailable") }
            if let runs {
                if runs.collectionRuns.isEmpty {
                    NativeEmptyState(title: runs.total == 0 ? "No collection runs reported" : "No runs on this page", message: "The collection runs API returned no records for the current first page.")
                } else {
                    let states = ThreatIntelligenceOverviewMetrics.statusCounts(runs.collectionRuns.map(\.status))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(states.keys.sorted(), id: \.self) { state in
                            metric(label: "Run · \(state)", value: String(states[state] ?? 0))
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(sortedRuns.prefix(6))) { run in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: run.status?.lowercased() == "failed" ? "exclamationmark.triangle" : "clock")
                                    .foregroundStyle(run.status?.lowercased() == "failed" ? theme.danger : theme.accent)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.sourceId ?? "Source not reported")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1).textSelection(.enabled)
                                    Text([run.status, run.startedAt, run.finishedAt.map { "Finished \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
                                    if let issue = run.error ?? run.message, !issue.isEmpty {
                                        Text(issue).font(.system(size: 10)).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
                                    }
                                    if let rowCount = run.rowCount ?? run.rows, let captureCount = run.captureCount {
                                        Text("\(rowCount) rows · \(captureCount) captures")
                                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textTertiary)
                                    }
                                }
                                Spacer(minLength: 0)
                                ActionButton(title: "Open runs", icon: "arrow.up.right") { onOpenRoute("/dashboard/ti/runs") }
                            }
                            .padding(.vertical, 6)
                            if run.id != sortedRuns.prefix(6).last?.id { Divider() }
                        }
                    }
                }
            } else if !isLoading && runError.isEmpty {
                NativeEmptyState(title: "Run data has not loaded", message: "Refresh this overview to request collection activity.")
            }
        }
    }

    private var capturePanel: some View {
        NativeGroupPanel(title: "Recent captures", subtitle: captureSummary) {
            if !captureError.isEmpty { NativeNotice(message: captureError, title: "Capture metadata unavailable") }
            if let captures {
                if captures.captures.isEmpty {
                    NativeEmptyState(title: captures.total == 0 ? "No captures reported" : "No captures on this page", message: "The capture API returned no metadata rows for the current first page.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(sortedCaptures.prefix(8))) { capture in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "camera").foregroundStyle(theme.accent).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(captureTitle(capture))
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                                        .lineLimit(2).textSelection(.enabled)
                                    Text([capture.sourceName, capture.mediaType, capture.collectedAt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                                        .lineLimit(2).textSelection(.enabled)
                                    if capture.locatorRedacted == true { Text("Capture locator redacted").font(.system(size: 10)).foregroundStyle(theme.textTertiary) }
                                }
                                Spacer(minLength: 0)
                                ActionButton(title: "Open captures", icon: "arrow.up.right") { onOpenRoute("/dashboard/ti/captures") }
                            }
                            .padding(.vertical, 6)
                            if capture.id != sortedCaptures.prefix(8).last?.id { Divider() }
                        }
                    }
                }
            } else if !isLoading && captureError.isEmpty {
                NativeEmptyState(title: "Capture data has not loaded", message: "Refresh this overview to request capture metadata. Capture bodies are not requested.")
            }
        }
    }

    private var deliveryPanel: some View {
        NativeGroupPanel(title: "Delivery timing", subtitle: deliverySummary) {
            if !deliveryError.isEmpty { NativeNotice(message: deliveryError, title: "Delivery timing unavailable") }
            if let delivery {
                let counts = delivery.summary.counts
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                    metric(label: "Records", value: counts["recordCount"].map(String.init) ?? "—")
                    metric(label: "Awaiting alert", value: counts["awaitingAlertCount"].map(String.init) ?? "—")
                    metric(label: "Awaiting delivery", value: counts["awaitingDeliveryCount"].map(String.init) ?? "—")
                    metric(label: "Anomalies", value: counts["anomalyCount"].map(String.init) ?? "—")
                    metric(label: "Complete", value: counts["completeCount"].map(String.init) ?? "—")
                    metric(label: "Incomplete sample", value: String(ThreatIntelligenceOverviewMetrics.recordsWithMissingStages(delivery.items)))
                }
                Text("Sample: \(delivery.items.count) of \(delivery.page.total) records · \(ThreatIntelligenceOverviewMetrics.recordsWithTimestampAnomalies(delivery.items)) sampled records report timestamp anomalies · generated \(delivery.generatedAt)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if delivery.items.isEmpty {
                    NativeEmptyState(title: delivery.page.total == 0 ? "No delivery records" : "No records in this sample", message: "The timeliness API returned no records for its current global sample.")
                }
            } else if !isLoading && deliveryError.isEmpty {
                NativeEmptyState(title: "Delivery data has not loaded", message: "Refresh this overview to request delivery timing.")
            }
            ActionButton(title: "Open delivery timing", icon: "arrow.up.right") { onOpenRoute("/dashboard/ti/timeliness") }
        }
    }

    private var sourceSummary: String {
        guard let sources else { return "Global operational source inventory" }
        return "\(sources.rows.count) loaded of \(sources.total) sources · health counts describe this loaded page"
    }

    private var runSummary: String {
        guard let runs else { return "Collection run status and available output counts" }
        return "\(runs.collectionRuns.count) loaded of \(runs.total) runs · status counts describe this loaded page"
    }

    private var captureSummary: String {
        guard let captures else { return "Read-only capture metadata · bodies are not requested" }
        return "\(captures.captures.count) loaded of \(captures.total) captures · metadata only"
    }

    private var deliverySummary: String {
        guard let delivery else { return "Global delivery-stage summary and bounded record sample" }
        return "\(delivery.page.total) global records · \(delivery.items.count) sampled"
    }

    private var sortedRuns: [ThreatIntelligenceCollectionRunPage.Run] {
        (runs?.collectionRuns ?? []).sorted { dateValue($0.startedAt) > dateValue($1.startedAt) }
    }

    private var sortedCaptures: [ThreatIntelligenceCapturePage.Capture] {
        (captures?.captures ?? []).sorted { dateValue($0.collectedAt) > dateValue($1.collectedAt) }
    }

    private func dateValue(_ raw: String?) -> Date {
        guard let raw else { return .distantPast }
        return ISO8601DateFormatter().date(from: raw) ?? .distantPast
    }

    private func captureTitle(_ capture: ThreatIntelligenceCapturePage.Capture) -> String {
        let metadata = capture.metadata
        return metadata?.title ?? metadata?.headline ?? metadata?.threatActor ?? metadata?.actor ?? metadata?.domain ?? capture.sourceName ?? "Capture metadata"
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary).lineLimit(2)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(theme.text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(10)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.divider, lineWidth: 1))
    }

    @MainActor private func refresh() async {
        let requestedScope = scopeKey
        guard !isLoading || loadedScopeKey != requestedScope else { return }
        let current = UUID()
        requestID = current
        isLoading = true
        sourceError = ""
        runError = ""
        captureError = ""
        deliveryError = ""
        let settings = model.settings
        if loadedScopeKey != requestedScope {
            sources = nil
            runs = nil
            captures = nil
            delivery = nil
            loadedScopeKey = requestedScope
        }
        defer { if requestID == current { isLoading = false } }

        let client: ThreatIntelligenceOperationsClient
        do {
            client = try ThreatIntelligenceOperationsClient(settings: settings)
        } catch {
            guard stillCurrent(current, settings: settings) else { return }
            let message = error.localizedDescription
            sourceError = message
            runError = message
            captureError = message
            deliveryError = message
            return
        }

        do {
            let snapshot = try await client.loadOperationalSources(query: "", page: 1)
            guard stillCurrent(current, settings: settings) else { return }
            sources = snapshot
        } catch {
            guard stillCurrent(current, settings: settings) else { return }
            sourceError = error.localizedDescription
        }

        do {
            let snapshot = try await client.loadCollectionRuns(query: "", page: 1)
            guard stillCurrent(current, settings: settings) else { return }
            runs = snapshot
        } catch {
            guard stillCurrent(current, settings: settings) else { return }
            runError = error.localizedDescription
        }

        do {
            let snapshot = try await client.loadCaptures(query: "", page: 1)
            guard stillCurrent(current, settings: settings) else { return }
            captures = snapshot
        } catch {
            guard stillCurrent(current, settings: settings) else { return }
            captureError = error.localizedDescription
        }

        do {
            let snapshot = try await client.loadTimeliness()
            guard stillCurrent(current, settings: settings) else { return }
            delivery = snapshot
        } catch {
            guard stillCurrent(current, settings: settings) else { return }
            deliveryError = error.localizedDescription
        }
    }

    private func stillCurrent(_ id: UUID, settings: HanasandDesktopSettings) -> Bool {
        !Task.isCancelled && requestID == id && model.settings == settings
    }
}
