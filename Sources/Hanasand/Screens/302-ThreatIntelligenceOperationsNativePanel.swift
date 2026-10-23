import AppKit
import SwiftUI

enum ThreatIntelligenceOperationsSection: Equatable {
    case profiles
    case sources
    case timeliness
}

struct ThreatIntelligenceOperationsNativePanel: View {
    let section: ThreatIntelligenceOperationsSection

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var profiles: ThreatIntelligenceOperationsPage?
    @State private var sources: ThreatIntelligenceSourcePage?
    @State private var timeliness: ThreatIntelligenceTimelinessSnapshot?
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var statusFilter = ""
    @State private var page = 1
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var message = ""
    @State private var requestID = UUID()

    private var title: String {
        switch section {
        case .profiles: "Actor profiles"
        case .sources: "Intelligence sources"
        case .timeliness: "Delivery health"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: title, subtitle: subtitle) {
                controls
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if isLoading && currentPageIsEmpty {
                NativeGroupPanel(title: "Loading", subtitle: "Requesting authenticated read-only data") {
                    ProgressView().controlSize(.small)
                }
            } else if let error = messageIfFailed {
                NativeEmptyState(title: "Unable to load \(title.lowercased())", message: error)
            } else {
                content
            }
        }
        .task(id: scopeKey) { await load(reset: true) }
    }

    private var subtitle: String {
        switch section {
        case .profiles: "Search source-backed actor records · 50 per page"
        case .sources: "Read-only public source catalogue · sensitive locators remain redacted"
        case .timeliness: "Global analyst queue · read-only · latest 50 records"
        }
    }

    @ViewBuilder private var controls: some View {
        SearchFieldRow(
            placeholder: section == .profiles
                ? "Search actor names and aliases"
                : section == .sources ? "Search source names and types" : "Search actor, source, incident, or capture", text: $query
        )
        .frame(minWidth: 0, maxWidth: .infinity)
        if section == .timeliness {
            Picker("Queue", selection: $statusFilter) {
                Text("All records").tag("")
                Text("Needs first report").tag("unresolved_reference")
                Text("Timestamp anomalies").tag("anomaly")
                Text("Awaiting alert").tag("awaiting_alert")
                Text("Awaiting delivery").tag("awaiting_delivery")
                Text("Complete").tag("complete")
                Text("Rejected incidents").tag("excluded")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: statusFilter) { _, _ in Task { await load(reset: true) } }
        }
        HStack(spacing: 8) {
            ActionButton(title: "Search", icon: "magnifyingglass") {
                Task { await load(reset: true) }
            }
            .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).count > 200)
            ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                Task { await load(reset: false) }
            }
            .disabled(isLoading)
            if isLoading { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .profiles: profileContent
        case .sources: sourceContent
        case .timeliness: timelinessContent
        }
    }

    private var profileContent: some View {
        NativeGroupPanel(title: "Observed profiles", subtitle: "\(profiles?.total ?? 0) matching profiles · page \(profiles?.page ?? page)")
        {
            if let profiles, !profiles.profiles.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(profiles.profiles) { actor in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(actor.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text([actor.actorType, actor.reviewState].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !actor.aliases.isEmpty {
                                Text("Aliases: \(actor.aliases.joined(separator: ", "))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Text(
                                "\(actor.evidenceCount ?? 0) evidence · \(actor.sourceIDs.count) source links · Last seen \(date(actor.lastSeenAt))"
                            )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        if actor.id != profiles.profiles.last?.id { Divider() }
                    }
                }
                if let nextPage = profiles.nextPage {
                    ActionButton(title: "Load page \(nextPage)", icon: "chevron.right") {
                        page = nextPage
                        Task { await load(reset: false) }
                    }
                    .disabled(isLoading)
                }
            } else {
                NativeEmptyState(title: "No actor profiles", message: "No source-backed actor profiles matched this search.")
            }
        }
    }

    private var sourceContent: some View {
        NativeGroupPanel(
            title: "Public source catalogue", subtitle: "\(sources?.total ?? 0) matching sources · page \(sources?.page ?? page)"
        ) {
            if let sources, !sources.sources.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sources.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text([source.type, source.status, source.risk].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !source.tags.isEmpty {
                                Text(source.tags.joined(separator: " · "))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(
                                "\(source.operatingMode.metadataOnly ? "Metadata only" : source.operatingMode.accessMethod.isEmpty ? "Access method not reported" : source.operatingMode.accessMethod) · Last seen \(date(source.collection.lastSeenAt))\(source.locatorRedacted ? " · Locator redacted" : "")"
                            )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            if let url = source.url {
                                Button("Open public source") { NSWorkspace.shared.open(url) }
                                    .font(.system(size: 11, weight: .semibold))
                                    .buttonStyle(.link)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        if source.id != sources.sources.last?.id { Divider() }
                    }
                }
                if let nextPage = sources.nextPage {
                    ActionButton(title: "Load page \(nextPage)", icon: "chevron.right") {
                        page = nextPage
                        Task { await load(reset: false) }
                    }
                    .disabled(isLoading)
                }
            } else {
                NativeEmptyState(title: "No sources", message: "No public sources matched this search.")
            }
        }
    }

    private var timelinessContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Queue summary", subtitle: "Generated \(date(timeliness?.generatedAt ?? ""))") {
                let summary = timeliness?.summary.counts ?? [:]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                    metric("Records", summary["recordCount"])
                    metric("Unresolved", summary["unresolvedReferenceCount"])
                    metric("Anomalies", summary["anomalyCount"])
                    metric("Awaiting alert", summary["awaitingAlertCount"])
                    metric("Awaiting delivery", summary["awaitingDeliveryCount"])
                    metric("Complete", summary["completeCount"])
                }
            }
            NativeGroupPanel(title: "Timeliness records", subtitle: "\(timeliness?.page.total ?? 0) matching · global scope") {
                if let timeliness, !timeliness.items.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(timeliness.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title.isEmpty ? (item.actorName.isEmpty ? "Timeliness record" : item.actorName) : item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Text(
                                    [
                                        item.actorName, item.sourceName, item.sourceFamily,
                                        item.status.replacingOccurrences(of: "_", with: " "),
                                    ]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                                )
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                if !item.summary.isEmpty {
                                    Text(item.summary)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                if !item.missingStages.isEmpty {
                                    Text(
                                        "Missing stages: \(item.missingStages.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))"
                                    )
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                if !item.anomalies.isEmpty {
                                    Text("Timestamp issues: \(item.anomalies.joined(separator: ", "))")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                let populatedStages = item.stages.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
                                if !populatedStages.isEmpty {
                                    Text(
                                        populatedStages.map { "\($0.key.replacingOccurrences(of: "_", with: " ")) · \(date($0.value))" }
                                            .joined(separator: "  /  ")
                                    )
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                }
                                ForEach(item.sources) { source in
                                    if let url = source.url {
                                        Button(source.title) { NSWorkspace.shared.open(url) }
                                            .font(.system(size: 10, weight: .semibold))
                                            .buttonStyle(.link)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else if !source.title.isEmpty {
                                        Text("Source: \(source.title)")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(theme.textTertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            if item.id != timeliness.items.last?.id { Divider() }
                        }
                    }
                    if let nextCursor = timeliness.page.nextCursor {
                        ActionButton(title: "Load next records", icon: "chevron.down") {
                            self.nextCursor = nextCursor
                            Task { await load(reset: false) }
                        }
                        .disabled(isLoading)
                    }
                } else {
                    NativeEmptyState(
                        title: "No matching records",
                        message: "No retained global timeliness records matched the selected queue and search.")
                }
                if let quality = timeliness?.quality {
                    Divider()
                    Text("Evidence quality")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(quality.fields) { field in
                        Text(
                            "\(field.name) · \(field.coverage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—") · \(field.presentCount ?? 0) present / \(field.missingCount ?? 0) missing"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !quality.issues.isEmpty {
                        Text("Issues: \(quality.issues.map { "\($0.name) (\($0.count))" }.joined(separator: " · "))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(quality.bySourceClass) { group in
                        let missingCount = group.missing.values.reduce(0, +)
                        let issueCount = group.issues.values.reduce(0, +)
                        Text("\(group.name) · \(group.recordCount) records · \(missingCount) missing fields · \(issueCount) issues")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let stages = timeliness?.metrics.byStage, !stages.isEmpty {
                    Divider()
                    Text("Median / p95 / p99 latency by stage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(stages) { value in
                        Text(
                            "\(value.name.replacingOccurrences(of: "_", with: " ")) · \(duration(value.medianSeconds)) / \(duration(value.p95Seconds)) / \(duration(value.p99Seconds)) · n=\(value.sampleSize.map(String.init) ?? "—")"
                        )
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let groups = timeliness?.metrics.bySourceFamily, !groups.isEmpty {
                    Divider()
                    Text("Latency by source family")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(groups) { group in
                        Text("\(group.name) · \(group.recordCount) records · \(latencySummary(group.metrics))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let groups = timeliness?.metrics.byActor, !groups.isEmpty {
                    Divider()
                    Text("Latency by actor")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(groups) { group in
                        Text("\(group.name) · \(group.recordCount) records · \(latencySummary(group.metrics))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var currentPageIsEmpty: Bool {
        switch section {
        case .profiles: profiles == nil
        case .sources: sources == nil
        case .timeliness: timeliness == nil
        }
    }

    private var messageIfFailed: String? {
        message.hasPrefix("Could not load") ? message : nil
    }

    private var scopeKey: String {
        [
            model.settings.websiteBaseURL, model.settings.userID, model.settings.impersonatingUserID,
            model.settings.impersonationToken.isEmpty ? "own-account" : "impersonating", sectionKey,
        ].joined(separator: "|")
    }

    private var sectionKey: String {
        switch section {
        case .profiles: "profiles"
        case .sources: "sources"
        case .timeliness: "timeliness"
        }
    }

    private func load(reset: Bool) async {
        if isLoading { return }
        let current = UUID()
        requestID = current
        isLoading = true
        message = reset ? "Loading \(title.lowercased())" : "Refreshing \(title.lowercased())"
        let requestedSettings = model.settings
        if reset {
            page = 1
            nextCursor = nil
            profiles = nil
            sources = nil
            timeliness = nil
            submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        defer { if requestID == current { isLoading = false } }
        do {
            let client = try ThreatIntelligenceOperationsClient(settings: requestedSettings)
            switch section {
            case .profiles:
                let snapshot = try await client.loadProfiles(query: submittedQuery, page: page)
                guard stillCurrent(current, settings: requestedSettings) else { return }
                profiles = snapshot
                message = "Loaded \(snapshot.profiles.count) profiles on page \(snapshot.page) of \(snapshot.total) matching."
            case .sources:
                let snapshot = try await client.loadSources(query: submittedQuery, page: page)
                guard stillCurrent(current, settings: requestedSettings) else { return }
                sources = snapshot
                message = "Loaded \(snapshot.sources.count) public sources on page \(snapshot.page) of \(snapshot.total) matching."
            case .timeliness:
                let snapshot = try await client.loadTimeliness(
                    status: statusFilter, query: submittedQuery, cursor: reset ? nil : nextCursor)
                guard stillCurrent(current, settings: requestedSettings) else { return }
                timeliness = snapshot
                nextCursor = nil
                message = "Loaded \(snapshot.items.count) global timeliness records. This view is read-only."
            }
        } catch {
            guard stillCurrent(current, settings: requestedSettings) else { return }
            message = "Could not load \(title.lowercased()): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func stillCurrent(_ current: UUID, settings: HanasandDesktopSettings) -> Bool {
        !Task.isCancelled && requestID == current && model.settings == settings
    }

    private func metric(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value.map(String.init) ?? "—").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 7))
    }

    private func date(_ value: String) -> String {
        guard let parsed = ISO8601DateFormatter().date(from: value) else { return value.isEmpty ? "not recorded" : value }
        return DateFormatter.localizedString(from: parsed, dateStyle: .medium, timeStyle: .short)
    }

    private func duration(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 60 { return "\(Int(value.rounded()))s" }
        if value < 3600 { return String(format: "%.1fm", value / 60) }
        return String(format: "%.1fh", value / 3600)
    }

    private func latencySummary(_ metrics: [String: ThreatIntelligenceTimelinessSnapshot.Metrics.Value]) -> String {
        metrics.keys.sorted().compactMap { key in
            guard let metric = metrics[key] else { return nil }
            return "\(key) \(duration(metric.medianSeconds))/\(duration(metric.p95Seconds))/\(duration(metric.p99Seconds))"
        }
        .joined(separator: " · ")
    }
}
