import SwiftUI

struct InfrastructureContainersNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var snapshot: InfrastructureContainersSnapshot?
    @State private var access: InfrastructureViewsAccess?
    @State private var selectedID = ""
    @State private var searchText = ""
    @State private var runtimeLogs: InfrastructureRuntimeLogs?
    @State private var status = "Loading container inventory…"
    @State private var isLoading = false
    @State private var restartCandidate: InfrastructureContainer?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    FeatureCard(title: "Active containers", value: "\(snapshot.activeContainers.count)", icon: "shippingbox")
                    FeatureCard(title: "Running", value: "\(snapshot.activeContainers.filter(\.isRunning).count)", icon: "play.circle")
                    FeatureCard(title: "Source", value: snapshot.source.isEmpty ? "Not reported" : snapshot.source, icon: "externaldrive")
                }
                HStack(spacing: 10) {
                    SearchFieldRow(placeholder: "Search containers by name, status, image, or id", text: $searchText)
                    ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }
                        .disabled(isLoading)
                }
                if !snapshot.unavailableReason.isEmpty {
                    NativeInlineStatus(message: snapshot.unavailableReason, isError: true)
                }
                Text("Source sample: \(snapshot.generatedAt)")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                if filteredContainers.isEmpty {
                    NativeEmptyState(title: snapshot.activeContainers.isEmpty ? "No active containers returned" : "No matching containers",
                                     message: snapshot.activeContainers.isEmpty ? (snapshot.unavailableReason.isEmpty ? "The current inventory contains no active containers." : "Inventory is unavailable; an empty response does not prove there are no containers.") : "Adjust the search field.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(filteredContainers) { container in
                            containerCard(container)
                        }
                    }
                    if let selected, selectedID == selected.id {
                        containerDetails(selected)
                    }
                }
            } else {
                NativeEmptyState(title: "Container inventory", message: status)
                ActionButton(title: isLoading ? "Loading…" : "Load containers", icon: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading)
            }
            if let snapshot,
               status != "Ready",
               status != snapshot.unavailableReason,
               (status.contains("failed") || status.contains("sign in") || status.contains("access")) {
                NativeInlineStatus(message: status, isError: status.lowercased().contains("failed") || status.lowercased().contains("access") || status.lowercased().contains("sign in"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Restart Docker container?", isPresented: Binding(
            get: { restartCandidate != nil },
            set: { if !$0 { restartCandidate = nil } }
        ), titleVisibility: .visible) {
            if let candidate = restartCandidate {
                Button("Restart \(candidate.displayName)", role: .destructive) {
                    Task { await restart(candidate) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let candidate = restartCandidate {
                Text("This restarts \(candidate.displayName) in the Hanasand infrastructure. Current telemetry was sampled at \(snapshot?.generatedAt ?? "an unknown time").")
            }
        }
        .task { await load() }
    }

    private var filteredContainers: [InfrastructureContainer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = snapshot?.activeContainers ?? []
        guard !query.isEmpty else { return rows }
        return rows.filter { [ $0.id, $0.name, $0.image, $0.state, $0.health ].joined(separator: " ").lowercased().contains(query) }
    }

    private var selected: InfrastructureContainer? {
        filteredContainers.first(where: { $0.id == selectedID }) ?? filteredContainers.first
    }

    private func containerCard(_ container: InfrastructureContainer) -> some View {
        Button {
            selectedID = container.id
        } label: {
            NativeGroupPanel(title: container.displayName, subtitle: container.image.isEmpty ? container.id : container.image) {
                LazyVGrid(columns: [GridItem(.flexible(minimum: 0), alignment: .leading), GridItem(.flexible(minimum: 0), alignment: .leading)], alignment: .leading, spacing: 8) {
                    compactFact("State", container.state.isEmpty ? "Unknown" : container.state)
                    compactFact("Health", container.health)
                    compactFact("CPU", container.cpuLabel)
                    compactFact("Memory", container.memoryLabel)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedID == container.id ? theme.accent.opacity(0.75) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Inspect \(container.displayName), \(container.state), \(container.health)")
    }

    private func containerDetails(_ container: InfrastructureContainer) -> some View {
        NativeGroupPanel(title: container.displayName, subtitle: "Container details and runtime logs") {
            Text("ID  \(container.id)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 10) {
                detailFact("Image", container.image)
                detailFact("State", container.state)
                detailFact("Health", container.health)
                detailFact("CPU", container.cpuLabel)
                detailFact("Memory", "\(container.memoryLabel) / \(container.memoryLimitLabel)")
                detailFact("Memory percent", container.memoryPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                detailFact("Uptime", container.uptimeSeconds.map { "\(Int($0)) seconds" } ?? "Unavailable")
                detailFact("Restarts", container.restartCount.map(String.init) ?? "Unavailable")
                detailFact("Created", container.createdAt.isEmpty ? "Unavailable" : container.createdAt)
                detailFact("Stats updated", container.statsUpdatedAt.isEmpty ? "Unavailable" : container.statsUpdatedAt)
            }
            if !container.unavailableReason.isEmpty { NativeInlineStatus(message: container.unavailableReason, isError: true) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ports").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                Text(container.ports.isEmpty ? "None reported" : container.ports.map { "\($0.ip.isEmpty ? "*" : $0.ip):\($0.publicPort.map(String.init) ?? "private") → \($0.privatePort)/\($0.type)" }.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    containerActions(container)
                }
                VStack(alignment: .leading, spacing: 8) {
                    containerActions(container)
                }
            }
            if let runtimeLogs {
                Text("Runtime logs · \(runtimeLogs.source.isEmpty ? "source not reported" : runtimeLogs.source) · \(runtimeLogs.generatedAt)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                if !runtimeLogs.unavailableReason.isEmpty { NativeInlineStatus(message: runtimeLogs.unavailableReason, isError: true) }
                if runtimeLogs.entries.isEmpty {
                    Text(runtimeLogs.runtimeAvailable || runtimeLogs.nativeAvailable ? "No recent runtime entries returned." : "Runtime log sources are unavailable.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(Array(runtimeLogs.entries.prefix(24).enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.createdAt.isEmpty ? "Time unavailable" : entry.createdAt) · \(entry.level) · \(entry.source)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(theme.textSecondary)
                            Text(entry.message).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Showing up to 24 of the 120 recent runtime entries. The full Logs workflow may use a separate ingested Logs service.")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func containerActions(_ container: InfrastructureContainer) -> some View {
        ActionButton(title: "Review restart", icon: "arrow.clockwise") { restartCandidate = container }
            .disabled(access?.canWrite != true || !clientIsCurrent)
        ActionButton(title: "Refresh runtime logs", icon: "doc.text.magnifyingglass") { Task { await loadLogs(container) } }
        ActionButton(title: "Open full Logs", icon: "list.bullet.rectangle") {
            model.openNativeHanasandRoute(InfrastructureContainerLogsRoute.nativeRoute(for: container))
        }
    }

    private var clientIsCurrent: Bool {
        guard let snapshot else { return false }
        return snapshot.accountScope == currentScope
    }

    private var currentScope: String {
        "\(model.settings.apiBaseURL.normalizedBaseURL.absoluteString)|\(model.settings.cdnBaseURL.normalizedBaseURL.absoluteString)|\(model.userIDForRequests)"
    }

    private func compactFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
            Text(value.isEmpty ? "Unavailable" : value).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(7).background(theme.card, in: RoundedRectangle(cornerRadius: 7))
    }

    private func detailFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
            Text(value.isEmpty ? "Unavailable" : value).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(8).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private func makeClient() throws -> InfrastructureViewsClient {
        guard let apiURL = URL(string: model.settings.apiBaseURL.normalizedBaseURL.absoluteString),
              let cdnURL = URL(string: model.settings.cdnBaseURL.normalizedBaseURL.absoluteString) else { throw InfrastructureViewsError.insecureEndpoint }
        return try InfrastructureViewsClient(apiBaseURL: apiURL, cdnBaseURL: cdnURL, userID: model.userIDForRequests,
            token: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.impersonatingUserIDForRequests)
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        isLoading = true
        status = "Refreshing container inventory…"
        defer { isLoading = false }
        do {
            let client = try makeClient()
            let access = try await client.loadAccess()
            guard access.canRead else { throw InfrastructureViewsError.accessDenied }
            let latest = try await client.loadContainers()
            guard latest.accountScope == currentScope else { throw InfrastructureViewsError.invalidScope }
            self.access = access
            snapshot = latest
            if !latest.activeContainers.contains(where: { $0.id == selectedID }) { selectedID = latest.activeContainers.first?.id ?? "" }
            status = "Ready"
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor private func loadLogs(_ container: InfrastructureContainer) async {
        do {
            let client = try makeClient()
            guard client.accountScope == snapshot?.accountScope else { throw InfrastructureViewsError.invalidScope }
            runtimeLogs = try await client.loadRuntimeLogs(service: container.name)
            status = "Ready"
        } catch { status = error.localizedDescription }
    }

    @MainActor private func restart(_ container: InfrastructureContainer) async {
        restartCandidate = nil
        guard let snapshot, let access else { status = InfrastructureViewsError.accessDenied.localizedDescription; return }
        do {
            let client = try makeClient()
            try await client.restart(container: container, snapshot: snapshot, access: access)
            status = "Restart requested for \(container.displayName). Refresh to review current state."
            await load()
        } catch { status = error.localizedDescription }
    }
}

enum InfrastructureContainerLogsRoute {
    static func nativeRoute(for container: InfrastructureContainer) -> BrowserNativeRoute {
        BrowserNativeRoute(path: "/logs", label: "Logs", detailID: nil, caseContext: nil, section: nil,
                           query: ["service": container.name])
    }
}

struct InfrastructureBlocklistNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var entries: [InfrastructureBlocklistEntry] = []
    @State private var searchText = ""
    @State private var draft = InfrastructureBlocklistDraft()
    @State private var editingEntry: InfrastructureBlocklistEntry?
    @State private var pendingDelete: InfrastructureBlocklistEntry?
    @State private var pendingWrite: PendingWrite?
    @State private var status = "Loading blocklist…"
    @State private var isLoading = false

    private enum PendingWrite: Identifiable {
        case create
        case update(InfrastructureBlocklistEntry)
        var id: String { switch self { case .create: "create"; case let .update(entry): "update-\(entry.id)" } }
    }

    private var visibleEntries: [InfrastructureBlocklistEntry] {
        guard clientIsCurrent else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter { "\($0.kind.label) \($0.value) \($0.owner) \($0.location) \($0.signals.joined(separator: " "))".lowercased().contains(query) }
    }

    private var clientIsCurrent: Bool { entriesScope == currentScope }
    @State private var entriesScope = ""
    private var currentScope: String { "\(model.settings.cdnBaseURL.normalizedBaseURL.absoluteString)|\(model.userIDForRequests)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search type, value, owner, location, or signal", text: $searchText)
                ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await load() } }.disabled(isLoading)
                ActionButton(title: "Add rule", icon: "plus") { beginCreate() }.disabled(!clientIsCurrent || entriesScope.isEmpty)
            }
            NativeGroupPanel(title: "Blocklist", subtitle: "Showing the latest \(entries.count) entries returned by the service (maximum 100).") {
                if let message = statusMessage, !message.isEmpty { NativeInlineStatus(message: message, isError: !message.hasPrefix("Ready")) }
                if entries.isEmpty {
                    Text(clientIsCurrent ? "No blocklist entries returned." : "Load the blocklist using an account with system administrator access.")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                } else if visibleEntries.isEmpty {
                    Text("No entries match the current search.").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(visibleEntries) { entry in blocklistRow(entry) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: Binding(get: { editingEntry != nil || pendingCreateDraft }, set: { if !$0 { editingEntry = nil; pendingCreateDraft = false } })) {
            editForm
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 520)
                .padding(18)
                .background(theme.background)
        }
        .confirmationDialog("Apply blocklist change?", isPresented: Binding(get: { pendingWrite != nil }, set: { if !$0 { pendingWrite = nil } }), titleVisibility: .visible) {
            if let pendingWrite {
                Button(pendingWriteLabel(pendingWrite), role: .destructive) { Task { await apply(pendingWrite) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes production traffic controls for the whole account. The blocklist service confirms access using the system administrator role.")
        }
        .confirmationDialog("Delete blocklist entry?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let entry = pendingDelete {
                Button("Delete \(entry.value)", role: .destructive) { Task { await delete(entry) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the production traffic rule for \(pendingDelete?.value ?? "this value").")
        }
        .task { await load() }
    }

    @State private var pendingCreateDraft = false
    private var statusMessage: String? { status == "Ready" ? nil : status }

    private func blocklistRow(_ entry: InfrastructureBlocklistEntry) -> some View {
        NativeGroupPanel(title: entry.value, subtitle: "\(entry.kind.label) · Rule #\(entry.id)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                blockFact("Signals", entry.signals.isEmpty ? "None reported" : entry.signals.joined(separator: " · "))
                blockFact("Requests", entry.requests.map { $0.formatted() } ?? "Unavailable")
                blockFact("Owner", entry.owner.isEmpty ? "Unavailable" : entry.owner)
                blockFact("Location", entry.location.isEmpty ? "Unavailable" : entry.location)
                blockFact("Updated", entry.updatedAt.isEmpty ? "Unavailable" : entry.updatedAt)
            }
            HStack(spacing: 8) {
                ActionButton(title: "Edit", icon: "pencil") { beginEdit(entry) }.disabled(!clientIsCurrent)
                ActionButton(title: "Delete", icon: "trash") { pendingDelete = entry }.disabled(!clientIsCurrent)
            }
        }
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(editingEntry == nil ? "Add blocklist rule" : "Edit blocklist rule").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Button("Close") { editingEntry = nil; pendingCreateDraft = false }.buttonStyle(.plain)
            }
            Picker("Type", selection: $draft.kind) {
                ForEach(InfrastructureBlocklistEntry.Kind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented)
            TextField(draft.kind == .ip ? "IPv4 or IPv6 address" : "User agent", text: $draft.value)
                .textFieldStyle(.roundedBorder)
            if editingEntry != nil {
                Toggle("VPN", isOn: $draft.isVPN)
                Toggle("Proxy", isOn: $draft.isProxy)
                Toggle("Tor", isOn: $draft.isTor)
            } else {
                Text("Signal flags can be adjusted after the entry has been created.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            HStack {
                Button("Cancel") { editingEntry = nil; pendingCreateDraft = false }.buttonStyle(.bordered)
                Spacer()
                Button(editingEntry == nil ? "Review add" : "Review changes") {
                    pendingWrite = editingEntry.map(PendingWrite.update) ?? .create
                    editingEntry = nil
                    pendingCreateDraft = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !clientIsCurrent)
            }
        }
        .foregroundStyle(theme.text)
    }

    private func blockFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textSecondary)
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(7).background(theme.card, in: RoundedRectangle(cornerRadius: 7))
    }

    private func makeClient() throws -> InfrastructureViewsClient {
        let apiURL = model.settings.apiBaseURL.normalizedBaseURL
        let cdnURL = model.settings.cdnBaseURL.normalizedBaseURL
        return try InfrastructureViewsClient(apiBaseURL: apiURL, cdnBaseURL: cdnURL, userID: model.userIDForRequests,
            token: model.authTokenForRequests, impersonationToken: model.settings.impersonationToken,
            impersonatingUserID: model.impersonatingUserIDForRequests)
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        isLoading = true
        status = "Refreshing blocklist…"
        defer { isLoading = false }
        do {
            let client = try makeClient()
            let latest = try await client.loadBlocklist()
            guard client.accountScope == "\(model.settings.apiBaseURL.normalizedBaseURL.absoluteString)|\(currentScope)" else {
                throw InfrastructureViewsError.invalidScope
            }
            entries = latest
            entriesScope = currentScope
            status = "Ready · authorized as system administrator"
        } catch { status = error.localizedDescription }
    }

    private func beginCreate() {
        editingEntry = nil
        draft = InfrastructureBlocklistDraft()
        pendingCreateDraft = true
    }

    private func beginEdit(_ entry: InfrastructureBlocklistEntry) {
        draft = InfrastructureBlocklistDraft(entry: entry)
        editingEntry = entry
        pendingCreateDraft = false
    }

    private func pendingWriteLabel(_ write: PendingWrite) -> String {
        switch write {
        case .create: "Add rule"
        case .update: "Save rule changes"
        }
    }

    @MainActor private func apply(_ write: PendingWrite) async {
        pendingWrite = nil
        do {
            let client = try makeClient()
            guard client.accountScope == "\(model.settings.apiBaseURL.normalizedBaseURL.absoluteString)|\(model.settings.cdnBaseURL.normalizedBaseURL.absoluteString)|\(model.userIDForRequests)", clientIsCurrent else {
                throw InfrastructureViewsError.invalidScope
            }
            switch write {
            case .create:
                try await client.createBlocklistEntry(draft)
                status = "Rule added. Refresh to review the current blocklist."
            case let .update(entry):
                try await client.updateBlocklistEntry(entry, draft: draft, currentEntries: entries)
                status = "Rule updated. Refresh to review the current blocklist."
            }
            await load()
        } catch { status = error.localizedDescription }
    }

    @MainActor private func delete(_ entry: InfrastructureBlocklistEntry) async {
        pendingDelete = nil
        do {
            let client = try makeClient()
            guard clientIsCurrent else { throw InfrastructureViewsError.invalidScope }
            try await client.deleteBlocklistEntry(entry, currentEntries: entries)
            status = "Rule deleted. Refresh to review the current blocklist."
            await load()
        } catch { status = error.localizedDescription }
    }
}

private struct NativeInlineStatus: View {
    @Environment(\.desktopTheme) private var theme
    let message: String
    let isError: Bool

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isError ? theme.danger : theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }
}
