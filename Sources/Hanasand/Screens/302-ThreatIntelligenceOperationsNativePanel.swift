import AppKit
import SwiftUI

enum ThreatIntelligenceOperationsSection: Equatable {
    case profiles
    case sources
    case timeliness
}

enum ThreatSourceView: String, CaseIterable, Identifiable {
    case operations = "Operations"
    case catalogue = "Public catalogue"
    case runs = "Collection runs"
    case captures = "Captures"
    var id: String { rawValue }
}

enum ThreatIntelligenceOperationsRouteContext {
    static func validOrganizationID(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve malformed route scope so the authenticated loader can fail closed.
        return clean
    }

    static func validSourceID(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) == nil ? nil : clean
    }
}

struct ThreatIntelligenceOperationsNativePanel: View {
    let section: ThreatIntelligenceOperationsSection
    let initialOrganizationID: String?
    let selectedSourceID: String?

    init(
        section: ThreatIntelligenceOperationsSection,
        initialSourceView: ThreatSourceView = .operations,
        initialQuery: String = "",
        selectedSourceID: String? = nil,
        initialOrganizationID: String? = nil
    ) {
        self.section = section
        self.initialOrganizationID = ThreatIntelligenceOperationsRouteContext.validOrganizationID(initialOrganizationID)
        self.selectedSourceID = section == .sources ? ThreatIntelligenceOperationsRouteContext.validSourceID(selectedSourceID) : nil
        _sourceView = State(initialValue: initialSourceView)
        _query = State(initialValue: initialQuery)
        _submittedQuery = State(initialValue: initialQuery)
        _focusedSourceID = State(initialValue: self.selectedSourceID)
    }

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var profiles: ThreatIntelligenceOperationsPage?
    @State private var actorDirectory: DwmActorDirectoryPage?
    @State private var sources: ThreatIntelligenceSourcePage?
    @State private var operationalSources: ThreatIntelligenceOperationalSourcePage?
    @State private var collectionRuns: ThreatIntelligenceCollectionRunPage?
    @State private var captures: ThreatIntelligenceCapturePage?
    @State private var sourceView: ThreatSourceView = .operations
    @State private var timeliness: ThreatIntelligenceTimelinessSnapshot?
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var statusFilter = ""
    @State private var page = 1
    @State private var focusedSourceID: String?
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var showStatusConfirmation = false
    @State private var showRunConfirmation = false
    @State private var pendingSourceStatus: (source: ThreatIntelligenceOperationalSourcePage.Source, status: String)?
    @State private var pendingSourceRun: ThreatIntelligenceOperationalSourcePage.Source?
    @State private var loadedSourceSettings: HanasandDesktopSettings?
    @State private var message = ""
    @State private var requestID = UUID()

    private var title: String {
        switch section {
        case .profiles: initialOrganizationID == nil ? "Actor profiles" : "Monitored actors"
        case .sources:
            switch sourceView {
            case .operations: "Source operations"
            case .catalogue: "Public source catalogue"
            case .runs: "Collection runs"
            case .captures: "Capture history"
            }
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
        .onChange(of: selectedSourceID) { _, value in
            focusedSourceID = section == .sources ? ThreatIntelligenceOperationsRouteContext.validSourceID(value) : nil
            page = 1
            Task { await load(reset: true) }
        }
        .confirmationDialog("Change source status?", isPresented: $showStatusConfirmation, titleVisibility: .visible) {
            if let statusAction = pendingSourceStatus {
                Button(statusAction.status == "active" ? "Activate source" : "Pause source") {
                    let action = statusAction
                    pendingSourceStatus = nil
                    Task { await updateSourceStatus(action.source, status: action.status) }
                }
            }
            Button("Cancel", role: .cancel) { pendingSourceStatus = nil }
        } message: {
            Text("This changes collection eligibility for \(pendingSourceStatus?.source.name ?? "this source"). The server will recheck your account membership and source-operator role.")
        }
        .confirmationDialog("Queue a collection query?", isPresented: $showRunConfirmation, titleVisibility: .visible) {
            if pendingSourceRun != nil {
                Button("Queue query") {
                    let source = pendingSourceRun
                    pendingSourceRun = nil
                    if let source { Task { await queueRun(source) } }
                }
            }
            Button("Cancel", role: .cancel) { pendingSourceRun = nil }
        } message: {
            Text("This queues the configured query across collection adapters. The website control API does not restrict the run to the selected source.")
        }
    }

    private var subtitle: String {
        switch section {
        case .profiles: initialOrganizationID == nil
                ? "Search source-backed actor records · 50 per page"
                : "Organization-scoped actor overviews · website product snapshot"
        case .sources: sourceView == .operations
                ? "Global source health and collection activity · changes require confirmation"
                : sourceView == .catalogue
                    ? "Read-only public source catalogue · sensitive locators remain redacted"
                    : sourceView == .runs ? "Read-only global collection run history" : "Read-only bounded capture history · capture bodies are never requested"
        case .timeliness: "Global analyst queue · read-only · latest 50 records"
        }
    }

    @ViewBuilder private var controls: some View {
        if section == .sources {
            Picker("Source view", selection: $sourceView) {
                ForEach(ThreatSourceView.allCases) { view in Text(view.rawValue).tag(view) }
            }
            .pickerStyle(.segmented)
            .onChange(of: sourceView) { _, _ in Task { await load(reset: true) } }
        }
        SearchFieldRow(
            placeholder: section == .profiles
                ? "Search actor names and aliases"
                : section == .sources ? sourceView == .runs ? "Search source or run status" : sourceView == .captures ? "Search source or capture metadata" : "Search source names and types" : "Search actor, source, incident, or capture", text: $query
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
                if section == .sources && sourceView == .operations { focusedSourceID = nil }
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
        case .sources:
            switch sourceView {
            case .operations: operationalSourceContent
            case .catalogue: sourceContent
            case .runs: collectionRunContent
            case .captures: captureContent
            }
        case .timeliness: timelinessContent
        }
    }

    private var operationalSourceContent: some View {
        NativeGroupPanel(title: "Source operations", subtitle: "\(operationalSources?.total ?? 0) sources · page \(page) · global scope") {
            if let focusedSourceID {
                if let source = operationalSources?.rows.first(where: { $0.id == focusedSourceID }) {
                    focusedSourceContent(source)
                } else {
                    NativeEmptyState(title: "Source not found", message: "No operational source record matched ID \(focusedSourceID). The source record was not substituted with a text search result.")
                }
                ActionButton(title: "Back to source operations", icon: "arrow.left") {
                    self.focusedSourceID = nil
                    query = ""
                    Task { await load(reset: true) }
                }
                .disabled(isLoading)
            } else if let operationalSources, !operationalSources.rows.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(operationalSources.rows) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.name ?? "Unnamed source").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                            Text([source.family, source.type, source.lifecycleStatus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            let health = source.health
                            Text("\(health?.state ?? "not observed") · last check \(date(health?.lastAttemptAt ?? "")) · useful output \(date(health?.lastUsefulItemAt ?? ""))")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            let coverage = source.coverage
                            Text("\(coverage?.captureCount ?? 0) captures · \(coverage?.customerMatchCount ?? 0) customer matches · \(source.executable == true ? "executable" : "not executable")")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            if let reasons = source.qualification?.reasons, !reasons.isEmpty {
                                Text("Qualification: \(reasons.joined(separator: ", "))").font(.system(size: 10)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            }
                            if let failure = health?.lastFailureReason, !failure.isEmpty {
                                Text("Latest failure: \(failure)").font(.system(size: 10)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            HStack(spacing: 8) {
                                Button(source.lifecycleStatus == "active" ? "Pause" : "Activate") {
                                    pendingSourceStatus = (source, source.lifecycleStatus == "active" ? "paused" : "active")
                                    showStatusConfirmation = true
                                }
                                .disabled(isLoading || isMutating || !canMutateLoadedSources)
                                if source.lifecycleStatus == "active" {
                                    Button("Run query") {
                                        pendingSourceRun = source
                                        showRunConfirmation = true
                                    }
                                    .disabled(isLoading || isMutating || !canMutateLoadedSources)
                                }
                            }
                            .font(.system(size: 10, weight: .semibold))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        if source.id != operationalSources.rows.last?.id { Divider() }
                    }
                }
                paginationControls(hasNext: page < max(1, Int(ceil(Double(operationalSources.total) / 50.0))))
            } else {
                NativeEmptyState(title: "No operational sources", message: "No source operations matched this search. Global inventory requires a source admin or source operator role.")
            }
        }
    }

    @ViewBuilder private func focusedSourceContent(_ source: ThreatIntelligenceOperationalSourcePage.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.name ?? "Unnamed source")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("ID: \(source.id)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .textSelection(.enabled)
            Text([source.family, source.type, source.lifecycleStatus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let health = source.health {
                Text("Health: \(health.state ?? "not observed") · last check \(date(health.lastAttemptAt ?? "") ) · useful output \(date(health.lastUsefulItemAt ?? ""))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = health.lastFailureReason, !failure.isEmpty {
                    Text("Latest failure: \(failure)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let coverage = source.coverage {
                Text("\(coverage.captureCount ?? 0) captures · \(coverage.customerMatchCount ?? 0) customer matches · \(source.executable == true ? "executable" : "not executable")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reasons = source.qualification?.reasons, !reasons.isEmpty {
                Text("Qualification: \(reasons.joined(separator: ", "))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(source.lifecycleStatus == "active" ? "Pause" : "Activate") {
                    pendingSourceStatus = (source, source.lifecycleStatus == "active" ? "paused" : "active")
                    showStatusConfirmation = true
                }
                .disabled(isLoading || isMutating || !canMutateLoadedSources)
                if source.lifecycleStatus == "active" {
                    Button("Run query") {
                        pendingSourceRun = source
                        showRunConfirmation = true
                    }
                    .disabled(isLoading || isMutating || !canMutateLoadedSources)
                }
            }
            .font(.system(size: 10, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var collectionRunContent: some View {
        NativeGroupPanel(title: "Collection runs", subtitle: "\(collectionRuns?.total ?? 0) recorded runs · page \(page)") {
            if let collectionRuns, !collectionRuns.collectionRuns.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(collectionRuns.collectionRuns) { run in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(run.sourceId ?? "Global source fleet").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                            Text("\(run.status ?? "status not reported") · started \(date(run.startedAt ?? "")) · \(run.captureCount ?? run.rows ?? run.rowCount ?? 0) captures/items")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            if let message = run.message ?? run.error, !message.isEmpty { Text(message).font(.system(size: 10)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        if run.id != collectionRuns.collectionRuns.last?.id { Divider() }
                    }
                }
                paginationControls(hasNext: collectionRuns.nextCursor != nil)
            } else { NativeEmptyState(title: "No collection runs", message: "No collection runs matched this search.") }
        }
    }

    private var captureContent: some View {
        NativeGroupPanel(title: "Capture history", subtitle: "\(captures?.total ?? 0) records · page \(page) · safe metadata only") {
            if let captures, !captures.captures.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(captures.captures) { capture in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(capture.metadata?.title ?? capture.metadata?.headline ?? capture.sourceName ?? "Source capture").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                            Text("\(capture.metadata?.actor ?? capture.metadata?.threatActor ?? capture.sourceId ?? "Source") · \(date(capture.collectedAt ?? ""))")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            Text("\(capture.metadata?.domain ?? "domain not reported") · \(capture.storageKind ?? capture.mediaType ?? "capture")\(capture.locatorRedacted == true ? " · locator redacted" : "")")
                                .font(.system(size: 10)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        if capture.id != captures.captures.last?.id { Divider() }
                    }
                }
                paginationControls(hasNext: captures.nextCursor != nil)
            } else { NativeEmptyState(title: "No captures", message: "No safe capture metadata matched this search. Capture bodies are intentionally not requested.") }
        }
    }

    @ViewBuilder private var profileContent: some View {
        if initialOrganizationID != nil {
            actorDirectoryContent
        } else {
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
    }

    private var actorDirectoryContent: some View {
        let needle = submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actors = (actorDirectory?.actorOverviews ?? []).filter { actor in
            needle.isEmpty || ([actor.actor] + actor.aliases).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        return NativeGroupPanel(
            title: "Monitored actor directory",
            subtitle: "\(actors.count) matching of \(actorDirectory?.actorOverviews.count ?? 0) organization-scoped actor overviews") {
                if !actors.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(actors) { actor in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(actor.actor)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                if !actor.aliases.isEmpty {
                                    Text("Aliases: \(actor.aliases.joined(separator: ", "))")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text("\(actor.watchState.replacingOccurrences(of: "_", with: " ")) · confidence \(actor.confidence.formatted(.percent.precision(.fractionLength(0)))) · \(actor.sourceCount) sources · \(actor.captureCount) captures · Last seen \(date(actor.latestSeenAt ?? ""))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !actor.sourceFamilies.isEmpty {
                                    Text("Source families: \(actor.sourceFamilies.joined(separator: ", "))")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !actor.summary.isEmpty {
                                    Text(actor.summary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                ActionButton(title: "Search actor in threat intelligence", icon: "magnifyingglass") {
                                    model.openNativeDashboard(path: "/ti", label: "Threat intelligence: \(actor.actor)", query: ["query": actor.actor])
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            if actor.id != actors.last?.id { Divider() }
                        }
                    }
                } else {
                    NativeEmptyState(
                        title: actorDirectory == nil ? "No actor directory" : "No monitored actors",
                        message: actorDirectory == nil
                            ? "No organization-scoped actor overview is available. Confirm the selected organization and refresh."
                            : "No monitored actor matched this name or alias.")
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
                                Button("Open public source") { model.openURL(url.absoluteString, label: "Public source") }
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
                                        Button(source.title) { model.openURL(url.absoluteString, label: source.title) }
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
        case .profiles: initialOrganizationID == nil ? profiles == nil : actorDirectory == nil
        case .sources:
            switch sourceView {
            case .operations: operationalSources == nil
            case .catalogue: sources == nil
            case .runs: collectionRuns == nil
            case .captures: captures == nil
            }
        case .timeliness: timeliness == nil
        }
    }

    private var messageIfFailed: String? {
        message.hasPrefix("Could not load") ? message : nil
    }

    private var canMutateLoadedSources: Bool {
        loadedSourceSettings != nil && model.settings == loadedSourceSettings
    }

    private var scopeKey: String {
        [
            model.settings.websiteBaseURL, model.settings.userID, model.settings.impersonatingUserID,
            model.settings.impersonationToken.isEmpty ? "own-account" : "impersonating", sectionKey,
            initialOrganizationID ?? "no-organization-filter",
        ].joined(separator: "|")
    }

    private var sectionKey: String {
        switch section {
        case .profiles: "profiles"
        case .sources: "sources-\(sourceView.rawValue)"
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
            actorDirectory = nil
            sources = nil
            operationalSources = nil
            collectionRuns = nil
            captures = nil
            timeliness = nil
            submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        defer { if requestID == current { isLoading = false } }
        do {
            switch section {
            case .profiles:
                if let initialOrganizationID {
                    let snapshot = try await model.loadDwmActorDirectory(organizationID: initialOrganizationID)
                    guard stillCurrent(current, settings: requestedSettings) else { return }
                    actorDirectory = snapshot
                    let filteredCount = snapshot.actorOverviews.filter { actor in
                        submittedQuery.isEmpty || ([actor.actor] + actor.aliases).contains { $0.localizedCaseInsensitiveContains(submittedQuery) }
                    }.count
                    message = "Loaded \(filteredCount) matching actor overviews from the selected organization."
                } else {
                    let client = try ThreatIntelligenceOperationsClient(settings: requestedSettings)
                    let snapshot = try await client.loadProfiles(query: submittedQuery, page: page)
                    guard stillCurrent(current, settings: requestedSettings) else { return }
                    profiles = snapshot
                    message = "Loaded \(snapshot.profiles.count) profiles on page \(snapshot.page) of \(snapshot.total) matching."
                }
            case .sources:
                let client = try ThreatIntelligenceOperationsClient(settings: requestedSettings)
                switch sourceView {
                case .operations:
                    let sourceLookupID = focusedSourceID
                    let snapshot = try await client.loadOperationalSources(query: sourceLookupID ?? submittedQuery, page: sourceLookupID == nil ? page : 1)
                    guard stillCurrent(current, settings: requestedSettings) else { return }
                    operationalSources = snapshot
                    loadedSourceSettings = requestedSettings
                    if let sourceLookupID, snapshot.rows.contains(where: { $0.id == sourceLookupID }) {
                        message = "Loaded selected source \(sourceLookupID). Changes require confirmation."
                    } else if let sourceLookupID {
                        message = "No operational source record matched ID \(sourceLookupID)."
                    } else {
                        message = "Loaded \(snapshot.rows.count) operational sources on page \(page) of \(snapshot.total) matching. Changes require confirmation."
                    }
                case .catalogue:
                    let snapshot = try await client.loadSources(query: submittedQuery, page: page)
                    guard stillCurrent(current, settings: requestedSettings) else { return }
                    sources = snapshot
                    message = "Loaded \(snapshot.sources.count) public sources on page \(snapshot.page) of \(snapshot.total) matching."
                case .runs:
                    let snapshot = try await client.loadCollectionRuns(query: submittedQuery, page: page)
                    guard stillCurrent(current, settings: requestedSettings) else { return }
                    collectionRuns = snapshot
                    message = "Loaded \(snapshot.collectionRuns.count) collection runs on page \(page) of \(snapshot.total) matching. This view is read-only."
                case .captures:
                    let snapshot = try await client.loadCaptures(query: submittedQuery, page: page)
                    guard stillCurrent(current, settings: requestedSettings) else { return }
                    captures = snapshot
                    message = "Loaded \(snapshot.captures.count) capture metadata records on page \(page) of \(snapshot.total) matching. This view is read-only."
                }
            case .timeliness:
                let client = try ThreatIntelligenceOperationsClient(settings: requestedSettings)
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

    private func updateSourceStatus(_ source: ThreatIntelligenceOperationalSourcePage.Source, status: String) async {
        guard canMutateLoadedSources, operationalSources?.rows.contains(where: { $0.id == source.id }) == true else {
            message = "The signed-in account or source inventory changed. Refresh before changing this source."
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let client = try ThreatIntelligenceOperationsClient(settings: model.settings)
            try await client.updateSourceStatus(source: source, status: status)
            guard model.settings == loadedSourceSettings else {
                message = "The account changed while the request was completing. Refresh the source inventory to verify its status."
                return
            }
            message = "Source status confirmed as \(status)."
            await load(reset: true)
        } catch {
            if case ThreatIntelligenceOperationsError.mutationOutcomeUnknown = error {
                await load(reset: true)
                let observed = operationalSources?.rows.first(where: { $0.id == source.id })?.lifecycleStatus
                message = observed == status
                    ? "Source status was verified after refreshing the inventory."
                    : "The change was not confirmed. Refreshed status: \(observed ?? "unavailable"). Do not retry until you verify current state."
            } else {
                message = "Could not confirm the source change: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func queueRun(_ source: ThreatIntelligenceOperationalSourcePage.Source) async {
        guard canMutateLoadedSources, operationalSources?.rows.contains(where: { $0.id == source.id }) == true else {
            message = "The signed-in account or source inventory changed. Refresh before queuing a run."
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let client = try ThreatIntelligenceOperationsClient(settings: model.settings)
            try await client.queueCollectionQuery(source: source, queries: source.coverage?.observedDomains ?? [])
            guard model.settings == loadedSourceSettings else {
                message = "The account changed while the request was completing. Check collection history before retrying."
                return
            }
            message = "Collection query was queued. This control route records runs in the dashboard tenant, separate from the global run list."
        } catch {
            if case ThreatIntelligenceOperationsError.mutationOutcomeUnknown = error {
                message = "The run receipt is ambiguous. This route writes to the dashboard tenant, which is not exposed in this global history view. Verify that tenant's run records before retrying."
            } else {
                message = "Could not confirm the collection request: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
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

    @ViewBuilder
    private func paginationControls(hasNext: Bool) -> some View {
        if page > 1 || hasNext {
            HStack {
                if page > 1 {
                    ActionButton(title: "Previous page", icon: "chevron.left") {
                        page = max(1, page - 1)
                        Task { await load(reset: false) }
                    }.disabled(isLoading)
                }
                Spacer(minLength: 8)
                if hasNext {
                    ActionButton(title: "Next page", icon: "chevron.right") {
                        page += 1
                        Task { await load(reset: false) }
                    }.disabled(isLoading)
                }
            }
        }
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
