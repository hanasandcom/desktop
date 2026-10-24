import SwiftUI

struct ActorEnrichmentNativePanel: View {
    enum Section: Equatable { case enrichment, activity }
    let section: Section

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var overview: ActorEnrichmentOverview?
    @State private var runs: ActorEnrichmentRunPage?
    @State private var query = ""
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
                            .onSubmit { Task { await load() } }
                        Button("Search") { Task { await load() } }
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
                    profiles(overview)
                    runHistory
                } else {
                    activityList(overview)
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
        return NativeGroupPanel(title: "Worker status", subtitle: status.worker.currentFailure ?? (status.worker.snapshotFresh == false ? "Latest status snapshot is stale." : "Actor profile evidence activity is current.")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                metric("Worker", status.worker.state)
                metric("Queued", String(status.queued))
                metric("Updated last hour", String(status.productivity?.profiles ?? 0))
                metric("New facts", String(status.productivity?.newFacts ?? 0))
                metric("Evidence words", String(status.productivity?.wordsAdded ?? 0))
                metric("Latest run", status.latestRun?.status ?? "none")
            }
        }
    }

    private func profiles(_ value: ActorEnrichmentOverview) -> some View {
        NativeGroupPanel(title: "Observed actor profiles", subtitle: "\(value.profiles.count) profiles · updated from retained public evidence") {
            if value.profiles.isEmpty {
                Text("No actor profiles are available yet.").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
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
                    }
                    .padding(.vertical, 7)
                    if profile.id != value.profiles.last?.id { Divider() }
                }
            }
        }
    }

    private func activityList(_ value: ActorEnrichmentOverview) -> some View {
        let events = updates.filter { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            ($0.actorName ?? $0.actorID).localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) || ($0.sourceName ?? $0.sourceID ?? "").localizedCaseInsensitiveContains(query) }
        return NativeGroupPanel(title: "Latest actor observations", subtitle: "\(events.count) evidence update records · this feed is independent of collection runs") {
            if events.isEmpty {
                NativeEmptyState(title: "No actor observations", message: query.isEmpty ? "No evidence-backed actor profile changes have been recorded." : "No actor observations match this search.")
            } else {
                ForEach(events.prefix(100)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.actorName ?? event.actorID).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                            Spacer()
                            Text(date(event.observedAt)).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        }
                        Text(event.summary).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        Text("\(event.sourceName ?? event.sourceID ?? "retained evidence") · \(event.captureIDs.count) captures")
                            .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }.padding(.vertical, 7)
                    if event.id != events.prefix(100).last?.id { Divider() }
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
            async let overviewRequest = client.loadOverview(query: section == .activity ? query : "")
            async let runsRequest = client.loadRuns()
            let (newOverview, newRuns) = try await (overviewRequest, runsRequest)
            guard requestID == current, model.settings == settings, !Task.isCancelled else { return }
            overview = newOverview; runs = newRuns; loadedSettings = settings
            message = "Loaded \(newOverview.profiles.count) actor profiles, \(newOverview.updates.count) profile evidence updates, and \(newRuns.runs.count) enrichment runs."
        } catch {
            guard requestID == current, model.settings == settings else { return }
            message = "Could not load actor enrichment: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
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
