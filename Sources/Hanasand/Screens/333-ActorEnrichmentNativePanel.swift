import SwiftUI

struct ActorEnrichmentNativePanel: View {
    enum Section: Equatable { case enrichment, activity }
    let section: Section

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var overview: ActorEnrichmentOverview?
    @State private var runs: ActorEnrichmentRunPage?
    @State private var profiles: [ThreatIntelligenceOperationsPage.Profile] = []
    @State private var profileTotal = 0
    @State private var nextProfilePage: Int?
    @State private var failedProfilePage: Int?
    @State private var selectedProfileID: String?
    @State private var query = ""
    @State private var activityPage = 1
    @State private var message = ""
    @State private var isLoading = false
    @State private var isQueuing = false
    @State private var showQueueConfirmation = false
    @State private var loadedSettings: HanasandDesktopSettings?
    @State private var requestID = UUID()

    private var title: String { section == .activity ? "Actor activity" : "Automated enrichment" }
    private var updates: [ActorEnrichmentOverview.Update] {
        (overview?.updates ?? []).sorted { $0.observedAt > $1.observedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: title, subtitle: section == .activity
                ? "Evidence-backed actor profile changes, separate from collection runs."
                : "Actor profile enrichment worker, queue, productivity, and run history.") {
                HStack {
                    if section == .activity {
                        TextField("Search actors or evidence", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { activityPage = 1; Task { await load() } }
                        Button("Search") { activityPage = 1; Task { await load() } }
                    }
                    Button(isLoading ? "Refreshing…" : "Refresh") { Task { await load() } }
                        .disabled(isLoading || isQueuing)
                    if section == .enrichment {
                        Button("Run enrichment…") { showQueueConfirmation = true }
                            .disabled(isLoading || isQueuing || !canQueue)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let overview {
                statusCards(overview)
                if section == .enrichment {
                    enrichmentProfiles(overview)
                    if !overview.profiles.isEmpty {
                        latestEvidence(overview)
                        profileHistory(overview)
                    }
                    runHistory
                } else {
                    activityMetrics(overview)
                    activityList
                    recentlyObservedProfiles
                }
            } else if !isLoading {
                NativeEmptyState(title: "Actor enrichment unavailable", message: message.isEmpty ? "Refresh to load actor profile enrichment data." : message)
            }
        }
        .padding(16)
        .task { await load() }
        .confirmationDialog("Queue actor enrichment?", isPresented: $showQueueConfirmation, titleVisibility: .visible) {
            Button("Queue run", role: .destructive) { Task { await queueRun() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This asks the server to start an explicit enrichment pass for the default tenant. The server will validate your account permissions.")
        }
    }

    private var canQueue: Bool { loadedSettings != nil && loadedSettings == model.settings }

    private func statusCards(_ value: ActorEnrichmentOverview) -> some View {
        let status = value.status
        return NativeGroupPanel(title: section == .activity ? "Activity status" : "Worker status", subtitle: status.worker.currentFailure ?? (status.worker.snapshotFresh == false ? "Latest status snapshot is stale." : "Actor profile evidence activity is current.")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                metric("Worker", status.worker.state)
                metric("Queued", String(status.queued))
                metric(section == .activity ? "Actors updated · past hour" : "Updated last hour", String(status.productivity?.profiles ?? 0))
                if section == .enrichment {
                    metric("New facts", String(status.productivity?.newFacts ?? 0))
                    metric("Evidence words", String(status.productivity?.wordsAdded ?? 0))
                    let profilesUpdated = status.productivity?.profiles ?? 0
                    let wordsAdded = status.productivity?.wordsAdded ?? 0
                    metric("Words per enriched profile", String(profilesUpdated > 0 ? wordsAdded / profilesUpdated : 0))
                    metric("Latest run failures", String(status.latestRun?.failureCount ?? 0))
                } else {
                    metric("Recent observations", String(updates.count))
                    metric("Actor profiles", String(profileTotal))
                }
                metric("Latest run", status.latestRun?.status ?? "none")
            }
        }
    }

    private var activityProfilesList: some View {
        NativeGroupPanel(title: "Recently observed actors", subtitle: "\(profiles.count) of \(profileTotal) profiles · updated from retained public evidence") {
            if profiles.isEmpty && !isLoading {
                NativeEmptyState(title: "No actor profiles yet", message: query.isEmpty ? "Actor profiles appear when collected intelligence identifies a named actor or group." : "No actor profiles match this search.")
            } else {
                ForEach(profiles) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button {
                                selectedProfileID = selectedProfileID == profile.id ? nil : profile.id
                            } label: {
                                HStack(spacing: 6) {
                                    Text(profile.name.isEmpty ? (profile.normalizedName.isEmpty ? profile.id : profile.normalizedName) : profile.name)
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                                    Image(systemName: selectedProfileID == profile.id ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Text(date(profile.updatedAt.isEmpty ? profile.lastSeenAt : profile.updatedAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text("\(profile.actorType.isEmpty ? "Type not reported" : profile.actorType) · \(profile.reviewState.isEmpty ? "Review state not reported" : profile.reviewState) · \(profile.evidenceCount.map { String($0) } ?? "Evidence count not reported") evidence records · confidence \(profile.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "not reported")")
                            .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                        if !profile.aliases.isEmpty {
                            Text("Aliases: \(profile.aliases.joined(separator: ", "))").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text("Last observed: \(date(profile.lastSeenAt))").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        if selectedProfileID == profile.id {
                            profileDetails(profile)
                        }
                    }
                    .padding(.vertical, 7)
                    if profile.id != profiles.last?.id { Divider() }
                }
                if let failedProfilePage {
                    Button("Retry page \(failedProfilePage)") { Task { await loadProfilePage(failedProfilePage, appending: true) } }
                        .disabled(isLoading)
                }
                if let nextProfilePage, failedProfilePage == nil {
                    Button(isLoading ? "Loading profiles…" : "Load next 50 profiles") {
                        Task { await loadProfilePage(nextProfilePage, appending: true) }
                    }.disabled(isLoading)
                }
            }
        }
    }

    private func enrichmentProfiles(_ value: ActorEnrichmentOverview) -> some View {
        NativeGroupPanel(title: "Observed actor profiles", subtitle: "\(value.profiles.count) profiles · updated from retained public evidence") {
            if value.profiles.isEmpty {
                NativeEmptyState(title: "No actor profiles yet", message: "Actor profiles appear when collected intelligence identifies a named actor or group.")
            } else {
                ForEach(value.profiles) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(profile.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                            Spacer()
                            Text(date(profile.updatedAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text("\(profile.sourceIDs.count) sources · \(profile.evidenceCount) evidence records · confidence \(profile.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "not reported")")
                            .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                        if !profile.aliases.isEmpty {
                            Text("Aliases: \(profile.aliases.joined(separator: ", "))").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                    }.padding(.vertical, 7)
                    if profile.id != value.profiles.last?.id { Divider() }
                }
            }
        }
    }

    private func latestEvidence(_ value: ActorEnrichmentOverview) -> some View {
        let recent = Array(updates.prefix(12))
        return NativeGroupPanel(title: "Latest evidence", subtitle: "Newest automated observations with retained sources.") {
            if recent.isEmpty {
                Text("No evidence updates have been recorded yet.").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            } else {
                ForEach(recent) { update in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(update.actorName ?? update.actorID).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                            Spacer()
                            Text(date(update.observedAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text(update.summary).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        Text("\(update.sourceName ?? update.sourceID ?? "retained evidence") · \(update.captureIDs.count) captures")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }.padding(.vertical, 7)
                    if update.id != recent.last?.id { Divider() }
                }
            }
        }
    }

    private func profileHistory(_ value: ActorEnrichmentOverview) -> some View {
        let history = Array(updates.prefix(20))
        return NativeGroupPanel(title: "Profile history", subtitle: "Recent actor profile changes from retained evidence.") {
            if history.isEmpty {
                Text("No field-level profile changes have been recorded yet.").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            } else {
                ForEach(history) { update in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(update.actorName ?? value.profiles.first(where: { $0.id == update.actorID })?.name ?? "Actor profile")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                            Spacer()
                            Text(date(update.observedAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text("\(update.kind == "added" ? "Profile created" : "Profile updated") from retained evidence · \(update.summary)")
                            .font(.system(size: 11)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Text("\(update.sourceID ?? "source linked") · \(update.captureIDs.count) captures")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }.padding(.vertical, 7)
                    if update.id != history.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder private func profileDetails(_ profile: ThreatIntelligenceOperationsPage.Profile) -> some View {
        Text("Profile ID: \(profile.id)").font(.system(size: 10)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
        Text("First seen: \(date(profile.firstSeenAt)) · Last seen: \(date(profile.lastSeenAt)) · Updated: \(date(profile.updatedAt))")
            .font(.system(size: 10)).foregroundStyle(theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        Text("Source IDs: \(profile.sourceIDs.isEmpty ? "None reported" : profile.sourceIDs.joined(separator: ", "))")
            .font(.system(size: 10)).foregroundStyle(theme.textTertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        Text("Capture IDs: \(profile.captureIDs.isEmpty ? "None reported" : profile.captureIDs.joined(separator: ", "))")
            .font(.system(size: 10)).foregroundStyle(theme.textTertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func activityMetrics(_ value: ActorEnrichmentOverview) -> some View {
        let recent = updates.first
        return NativeGroupPanel(title: "Activity at a glance", subtitle: "Latest automated actor profile observations and retained evidence.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                metric("Events", String(updates.count))
                metric("Monitoring signals", "0")
                metric("Actors updated · past hour", String(value.status.productivity?.profiles ?? 0))
                metric("Last event", recent.map { date($0.observedAt) } ?? "No events yet")
            }
            if let failure = value.status.worker.currentFailure, !failure.isEmpty {
                Text("The latest profile update failed: \(failure)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if value.status.worker.snapshotFresh == false {
                Text("The latest profile update status is stale. Refresh to check for recovery.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recentlyObservedProfiles: some View { activityProfilesList }

    private var activityList: some View {
        let events = updates.filter { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            ($0.actorName ?? $0.actorID).localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) || ($0.sourceName ?? $0.sourceID ?? "").localizedCaseInsensitiveContains(query) }
        let pageCount = max(1, Int(ceil(Double(events.count) / 25)))
        let page = min(max(1, activityPage), pageCount)
        let visibleEvents = Array(events.dropFirst((page - 1) * 25).prefix(25))
        return NativeGroupPanel(title: "Latest actor observations", subtitle: "\(events.count) evidence update records · this feed is independent of collection runs") {
            if events.isEmpty {
                NativeEmptyState(title: "No actor observations", message: query.isEmpty ? "No evidence-backed actor profile changes have been recorded." : "No actor observations match this search.")
            } else {
                ForEach(visibleEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.actorName ?? event.actorID).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                            Spacer()
                            Text(date(event.observedAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text(event.summary).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        Text("\(event.sourceName ?? event.sourceID ?? "retained evidence") · \(event.captureIDs.count) captures")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        if let profile = profiles.first(where: { $0.id == event.actorID }) {
                            Button(selectedProfileID == profile.id ? "Close actor profile" : "View actor profile") {
                                selectedProfileID = selectedProfileID == profile.id ? nil : profile.id
                            }.buttonStyle(.link)
                            if selectedProfileID == profile.id { profileDetails(profile) }
                        }
                    }.padding(.vertical, 7)
                    if event.id != visibleEvents.last?.id { Divider() }
                }
                HStack {
                    Text("Page \(page) of \(pageCount)").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    Spacer()
                    Button("Previous") { activityPage = max(1, page - 1) }.disabled(page <= 1)
                    Button("Next") { activityPage = min(pageCount, page + 1) }.disabled(page >= pageCount)
                }
            }
        }
    }

    @ViewBuilder private var runHistory: some View {
        if let runs {
            NativeGroupPanel(title: "Enrichment run history", subtitle: "\(runs.total) recorded runs · distinct from source collection runs") {
                if runs.runs.isEmpty { Text("No enrichment runs have been recorded.").font(.system(size: 12)).foregroundStyle(theme.textTertiary) }
                ForEach(runs.runs) { run in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.status.capitalized).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                            Text("\(run.actorCount) actors · \(run.changedFieldCount) changed fields · \(run.evidenceCount) evidence · \(run.failureCount) failures")
                                .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                            if let error = run.error, !error.isEmpty { Text(error).font(.system(size: 10)).foregroundStyle(theme.textTertiary) }
                        }
                        Spacer()
                        Text(date(run.finishedAt ?? run.startedAt ?? "")).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }.padding(.vertical, 7)
                    if run.id != runs.runs.last?.id { Divider() }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 7))
    }

    private func load() async {
        guard !isLoading else { return }
        let current = UUID(); requestID = current; isLoading = true
        let settings = model.settings
        defer { if requestID == current { isLoading = false } }
        do {
            let client = try ActorEnrichmentClient(settings: settings)
            let operations = try ThreatIntelligenceOperationsClient(settings: settings)
            async let overviewRequest = client.loadOverview(query: section == .activity ? query : "")
            async let profilesRequest: ThreatIntelligenceOperationsPage? = section == .activity
                ? try await operations.loadProfiles(query: query, page: 1)
                : nil
            async let runsRequest = section == .enrichment ? client.loadRuns() : nil
            let (newOverview, firstProfiles, newRuns) = try await (overviewRequest, profilesRequest, runsRequest)
            guard requestID == current, model.settings == settings, !Task.isCancelled else { return }
            overview = newOverview; runs = newRuns; loadedSettings = settings
            profiles = firstProfiles?.profiles ?? []
            profileTotal = firstProfiles?.total ?? 0
            nextProfilePage = firstProfiles?.nextPage
            failedProfilePage = nil; selectedProfileID = nil
            activityPage = min(max(1, activityPage), max(1, Int(ceil(Double(newOverview.updates.count) / 25))))
            message = "Loaded \(profiles.count) of \(profileTotal) actor profiles and \(newOverview.updates.count) profile evidence updates."
        } catch {
            guard requestID == current, model.settings == settings else { return }
            message = "Could not load actor enrichment: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func loadProfilePage(_ page: Int, appending: Bool) async {
        guard !isLoading, (1...20_000).contains(page) else { return }
        let current = UUID(); requestID = current; isLoading = true
        let settings = model.settings
        defer { if requestID == current { isLoading = false } }
        do {
            let client = try ThreatIntelligenceOperationsClient(settings: settings)
            let result = try await client.loadProfiles(query: query, page: page)
            guard requestID == current, model.settings == settings, !Task.isCancelled else { return }
            if appending {
                profiles = profiles + result.profiles.filter { existing in !profiles.contains(where: { $0.id == existing.id }) }
            } else {
                profiles = result.profiles
            }
            profileTotal = result.total; nextProfilePage = result.nextPage; failedProfilePage = nil
            message = ""
        } catch {
            guard requestID == current, model.settings == settings else { return }
            failedProfilePage = page
            message = "Could not load actor profile page \(page): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func queueRun() async {
        guard canQueue, !isQueuing else { message = "Account changed. Refresh before queuing enrichment."; return }
        isQueuing = true; defer { isQueuing = false }
        do {
            let settings = model.settings
            try await ActorEnrichmentClient(settings: settings).queueRun()
            guard model.settings == settings else { message = "Request accepted, but the account changed. Refresh to verify the run."; return }
            message = "Enrichment run accepted. Refreshing status…"
            await load()
        } catch {
            message = "Could not confirm enrichment request: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func date(_ raw: String) -> String {
        guard let parsed = ISO8601DateFormatter().date(from: raw) else { return raw.isEmpty ? "not recorded" : raw }
        return DateFormatter.localizedString(from: parsed, dateStyle: .medium, timeStyle: .short)
    }
}
