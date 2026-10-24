import SwiftUI

struct DatabaseNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var client: NativeDatabaseClient?
    @State private var overview: NativeDatabaseOverview?
    @State private var access: NativeDatabaseAccess?
    @State private var health: NativeDatabaseHealth?
    @State private var browsePage: NativeDatabasePage?
    @State private var coreRows: NativeDatabaseQueryResult?
    @State private var sqlResult: NativeDatabaseQueryResult?
    @State private var selectedInstanceID = ""
    @State private var selectedDatabaseName = ""
    @State private var selectedTableID = ""
    @State private var browsableTables: [NativeDatabaseOverview.Table] = []
    @State private var sqlDraft = ""
    @State private var reviewedSQL: String?
    @State private var isLoading = false
    @State private var isBrowsing = false
    @State private var isRunningSQL = false
    @State private var isReviewingSQL = false
    @State private var sqlNeedsRefresh = false
    @State private var errorMessage = ""
    @State private var operationMessage = ""

    private var selectedInstance: NativeDatabaseOverview.Instance? {
        overview?.storage?.instances.first(where: { $0.id == selectedInstanceID })
    }
    private var selectedDatabase: NativeDatabaseOverview.Database? {
        selectedInstance?.databases.first(where: { $0.name == selectedDatabaseName })
    }
    private var selectedTable: NativeDatabaseOverview.Table? {
        let tables = selectedInstance?.engine.lowercased() == "redis"
            ? browsableTables
            : selectedDatabase?.tables ?? browsableTables
        return tables.first(where: { $0.id == selectedTableID })
    }
    private var credentialScope: String {
        "\(model.settings.apiBaseURL)|\(model.settings.internalAPIBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(model.settings.selectedOrganizationID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(isLoading || isBrowsing || isRunningSQL)
            }

            if !errorMessage.isEmpty {
                NativeNotice(message: errorMessage, title: "Database request failed")
            }
            if !operationMessage.isEmpty {
                NativeNotice(message: operationMessage, title: "Database operation", tone: .success)
            }
            if sqlNeedsRefresh {
                NativeNotice(message: "Refresh and review the current database state before submitting another statement.", title: "Review required", tone: .info)
            }

            if let overview {
                overviewSection(overview)
                storageSection(overview)
                querySection(overview)
                browserSection(overview)
                coreRowsSection
                sqlSection
            } else {
                NativeEmptyState(title: isLoading ? "Loading database overview" : "Database overview unavailable",
                                 message: isLoading ? "Checking access, database health and inventory." : (errorMessage.isEmpty ? "Refresh to load the internal database service." : errorMessage))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Run this SQL statement?", isPresented: $isReviewingSQL, titleVisibility: .visible) {
            Button("Run reviewed statement") { Task { await runSQL() } }
            Button("Cancel", role: .cancel) { reviewedSQL = nil }
        } message: {
            Text("Core database · owner/editor access\n\n\(reviewedSQL ?? "Review the SQL editor before continuing.")")
        }
        .task(id: credentialScope) { await refresh() }
    }

    @ViewBuilder
    private func overviewSection(_ value: NativeDatabaseOverview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
            FeatureCard(title: "Databases", value: value.databaseCount.map(String.init) ?? "Unavailable", icon: "externaldrive")
            FeatureCard(title: "Storage", value: value.totalSizeBytes.map(formatBytes) ?? "Unavailable", icon: "internaldrive")
            FeatureCard(title: "Active queries", value: String(value.querySummary?.count ?? value.activeQueries ?? 0), icon: "play.circle")
        }

        NativeGroupPanel(title: value.status == "healthy" ? "Database overview" : "Database unavailable", subtitle: value.generatedAt) {
            Text(value.health.message).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            if let category = value.health.category { fact("Category", category.capitalized) }
            if let detail = value.health.detail, !detail.isEmpty { fact("Detail", detail) }
            if let health {
                fact("Connection", health.ok ? "Connected to \(health.database ?? "Core")" : "Unavailable")
                if let checked = health.checkedAt { fact("Checked", checked) }
                if let message = health.message, !message.isEmpty { fact("Check result", message) }
            } else {
                fact("Connection", "Check unavailable")
            }
            if let average = value.averageQuerySeconds { fact("Average active query", String(format: "%.2f seconds", average)) }
        }
    }

    @ViewBuilder
    private func storageSection(_ value: NativeDatabaseOverview) -> some View {
        if let storage = value.storage {
            NativeGroupPanel(title: "Storage and database inventory", subtitle: "\(storage.host) · sampled \(storage.sampledAt)\(storage.stale == true ? " · stale" : "")") {
                fact("Disk free", "\(formatBytes(storage.disk.availableBytes)) / \(formatBytes(storage.disk.totalBytes))")
                fact("Growth per day", storage.disk.dailyGrowthBytes.map(formatBytes) ?? "Unavailable")
                fact("Estimated full", storage.disk.daysUntilFull.map { String(format: "%.1f days", $0) } ?? "Unavailable")
                if storage.instances.isEmpty {
                    Text("No database instances were reported.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                ForEach(storage.instances) { instance in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(instance.id) · \(instance.engine) · \(instance.status.capitalized)")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        ForEach(instance.databases) { database in
                            HStack {
                                Text(database.name).foregroundStyle(theme.text)
                                Spacer()
                                Text("\(database.sizeBytes.map(formatBytes) ?? "Unavailable") · \(database.connections.map { "\($0) connections" } ?? "connection count unavailable")")
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.top, 4)
                }
            }
        } else {
            NativeGroupPanel(title: "Storage inventory unavailable", subtitle: "Current database health does not include a storage sample.") {
                Text("Refresh after storage telemetry is available. An empty inventory does not mean storage is empty.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func querySection(_ value: NativeDatabaseOverview) -> some View {
        NativeGroupPanel(title: "Active queries", subtitle: "\(value.querySummary?.longRunningCount ?? value.queries.filter(\.isLongRunning).count) long-running") {
            if value.queries.isEmpty {
                Text("Query details are hidden in the summary response.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Load active query details", icon: "arrow.down.doc") { Task { await loadQueryDetails() } }
                    .disabled(isLoading || isBrowsing || isRunningSQL)
            } else {
                ForEach(Array(value.queries.enumerated()), id: \.offset) { _, query in
                    VStack(alignment: .leading, spacing: 5) {
                        fact("Database / user", "\(query.database ?? "Unknown database") · \(query.user ?? "Unknown user")")
                        fact("State / duration", "\(query.state ?? "Unknown") · \(query.durationSeconds.map { String(format: "%.1f sec", $0) } ?? "unknown duration")")
                        if query.waitEventType != nil || query.waitEvent != nil { fact("Wait", [query.waitEventType, query.waitEvent].compactMap { $0 }.joined(separator: " · ")) }
                        Text(query.query ?? "Query text unavailable").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func browserSection(_ value: NativeDatabaseOverview) -> some View {
        NativeGroupPanel(title: "Database browser", subtitle: "Read-only inventory and paged row previews") {
            if value.storage?.stale == true {
                NativeNotice(message: "The database inventory is stale. Refresh the overview before browsing.", title: "Inventory is stale", tone: .info)
            }
            if value.storage?.instances.isEmpty != false {
                Text("Database browser inventory is unavailable.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            } else {
                Picker("Instance", selection: $selectedInstanceID) {
                    ForEach(value.storage?.instances ?? []) { instance in Text("\(instance.id) · \(instance.engine)").tag(instance.id) }
                }
                .onChange(of: selectedInstanceID) { _, instanceID in
                    guard let instance = value.storage?.instances.first(where: { $0.id == instanceID }) else { return }
                    selectedDatabaseName = instance.databases.first?.name ?? ""
                    selectedTableID = ""
                    browsableTables = []
                    browsePage = nil
                    if let database = instance.databases.first { Task { await browseContents(instance: instance, database: database) } }
                }

                if let instance = selectedInstance {
                    Picker("Database", selection: $selectedDatabaseName) {
                        ForEach(instance.databases) { database in Text(database.name).tag(database.name) }
                    }
                    .onChange(of: selectedDatabaseName) { _, databaseName in
                        selectedTableID = ""
                        browsableTables = []
                        browsePage = nil
                        if let database = instance.databases.first(where: { $0.name == databaseName }) { Task { await browseContents(instance: instance, database: database) } }
                    }
                }

                if isBrowsing { ProgressView("Loading database preview…") }
                if let browsePage {
                    if let tables = browsePage.items {
                        if tables.isEmpty { Text("No tables or keys were returned.").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
                        ForEach(tables) { table in
                            Button {
                                selectedTableID = table.id
                                guard let instance = selectedInstance, let database = selectedDatabase else { return }
                                Task { await browse(instance: instance, database: database, table: table, mode: "rows") }
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(table.schema).\(table.name)").foregroundStyle(theme.text).lineLimit(1)
                                        Text("\(table.estimatedRows.map { "~\($0) rows" } ?? "row count unavailable") · \(table.sizeBytes.map(formatBytes) ?? "size unavailable")")
                                            .foregroundStyle(theme.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                                }
                                .font(.system(size: 12, weight: .medium)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let rows = browsePage.rows {
                        if rows.isEmpty { Text("No rows returned.").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in rowCard(row, title: "Row \(index + 1)") }
                    }
                    if let count = browsePage.totalRows { fact("Total rows", String(count)) }
                    HStack {
                        ActionButton(title: "Count rows", icon: "number") {
                            guard let instance = selectedInstance, let database = selectedDatabase, let table = selectedTable else { return }
                            Task { await browse(instance: instance, database: database, table: table, mode: "count") }
                        }
                        .disabled(selectedTable == nil || isBrowsing)
                        if browsePage.nextCursor != nil {
                            ActionButton(title: "Next rows", icon: "arrow.right") {
                                guard let instance = selectedInstance, let database = selectedDatabase, let table = selectedTable,
                                      let cursor = browsePage.nextCursor else { return }
                                Task { await browse(instance: instance, database: database, table: table, mode: "rows", cursor: cursor) }
                            }
                            .disabled(isBrowsing)
                        }
                    }
                    if let elapsed = browsePage.elapsedMs { fact("Query time", String(format: "%.0f ms", elapsed)) }
                }
            }
        }
    }

    @ViewBuilder
    private var coreRowsSection: some View {
        if selectedDatabase?.name.lowercased() == "core", let table = selectedTable {
            NativeGroupPanel(title: "Core table row preview", subtitle: "\(table.schema).\(table.name) · read-only · at most 50 rows") {
                ActionButton(title: isBrowsing ? "Loading…" : "Load Core rows", icon: "tablecells") { Task { await loadCoreRows(table) } }
                    .disabled(isBrowsing || access?.allowed != true)
                if let coreRows {
                    fact("Rows returned", "\(coreRows.rowCount)")
                    ForEach(Array(coreRows.rows.enumerated()), id: \.offset) { index, row in rowCard(row, title: "Core row \(index + 1)") }
                }
            }
        }
    }

    private var sqlSection: some View {
        NativeGroupPanel(title: "Reviewed SQL", subtitle: "Core database · submitted statements may change data") {
            TextEditor(text: $sqlDraft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("SQL statement")
            HStack {
                Text(access?.canEdit == true && isOwnAccount ? "Owner/editor access verified" : "Read-only session")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                Spacer()
                ActionButton(title: isRunningSQL ? "Running…" : "Review and run", icon: "play.fill") {
                    reviewedSQL = sqlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    isReviewingSQL = true
                }
                    .disabled(sqlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunningSQL || isLoading || sqlNeedsRefresh || access?.canEdit != true || !isOwnAccount)
            }
            if let sqlResult {
                fact("Rows affected / returned", String(sqlResult.rowCount))
                ForEach(Array(sqlResult.rows.enumerated()), id: \.offset) { index, row in rowCard(row, title: "SQL result \(index + 1)") }
            }
        }
    }

    private var isOwnAccount: Bool {
        model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refresh() async {
        guard !isLoading else { return }
        let requestedCredentialScope = credentialScope
        isLoading = true
        errorMessage = ""
        operationMessage = ""
        access = nil
        overview = nil
        browsePage = nil
        coreRows = nil
        sqlResult = nil
        sqlNeedsRefresh = false
        reviewedSQL = nil
        client = nil
        selectedInstanceID = ""
        selectedDatabaseName = ""
        selectedTableID = ""
        browsableTables = []
        defer {
            isLoading = false
            if credentialScope != requestedCredentialScope, model.selectedDashboardPath == "/db" {
                Task { await refresh() }
            }
        }
        do {
            let next = try NativeDatabaseClient(settings: model.settings)
            async let accessTask = next.loadAccess()
            async let overviewTask = next.loadOverview()
            async let healthTask = next.loadHealth()
            let (permissions, inventory, liveHealth) = try await (accessTask, overviewTask, healthTask)
            guard !Task.isCancelled, credentialScope == requestedCredentialScope, model.selectedDashboardPath == "/db" else { return }
            client = next
            access = permissions
            overview = inventory
            health = liveHealth
            if let instance = inventory.storage?.instances.first, let database = instance.databases.first {
                selectedInstanceID = instance.id
                selectedDatabaseName = database.name
                await browseContents(instance: instance, database: database)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadQueryDetails() async {
        guard let client, !isLoading else { return }
        let requestScope = client.scope
        isLoading = true
        defer { isLoading = false }
        do {
            let full = try await client.loadOverview(full: true)
            guard !Task.isCancelled, self.client?.scope == requestScope, model.selectedDashboardPath == "/db" else { return }
            overview = full
        } catch { errorMessage = error.localizedDescription }
    }

    private func browseContents(instance: NativeDatabaseOverview.Instance, database: NativeDatabaseOverview.Database) async {
        guard let overview else { return }
        await browse(instance: instance, database: database, mode: "contents")
        if overview.storage?.stale == true { errorMessage = "Inventory is stale; refresh before browsing." }
    }

    private func browse(instance: NativeDatabaseOverview.Instance, database: NativeDatabaseOverview.Database,
                        table: NativeDatabaseOverview.Table? = nil, mode: String, cursor: String? = nil) async {
        guard let client, let overview else { return }
        let requestScope = client.scope
        isBrowsing = true
        errorMessage = ""
        if mode != "count" { coreRows = nil }
        defer { isBrowsing = false }
        do {
            let page = try await client.browse(overview, instanceID: instance.id, databaseName: database.name, mode: mode,
                                               schema: table?.schema, table: table?.name, cursor: cursor,
                                               knownTableNames: Set(browsableTables.map(\.name)))
            guard !Task.isCancelled, self.client?.scope == requestScope, model.selectedDashboardPath == "/db" else { return }
            if mode == "contents" { browsableTables = page.items ?? [] }
            browsePage = page
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadCoreRows(_ table: NativeDatabaseOverview.Table) async {
        guard let client, let access else { return }
        let requestScope = client.scope
        isBrowsing = true
        errorMessage = ""
        defer { isBrowsing = false }
        do {
            let result = try await client.loadCoreRows(access: access, table: table)
            guard !Task.isCancelled, self.client?.scope == requestScope, model.selectedDashboardPath == "/db" else { return }
            coreRows = result
        } catch { errorMessage = error.localizedDescription }
    }

    private func runSQL() async {
        guard let client, let access, let reviewedSQL else { return }
        let requestScope = client.scope
        isRunningSQL = true
        errorMessage = ""
        operationMessage = ""
        sqlResult = nil
        defer { isRunningSQL = false; self.reviewedSQL = nil }
        do {
            let result = try await client.runReviewedSQL(reviewedSQL, access: access)
            guard !Task.isCancelled, self.client?.scope == requestScope, model.selectedDashboardPath == "/db" else { return }
            sqlResult = result
            operationMessage = "Statement completed and returned \(result.rowCount) row(s)."
        } catch {
            guard self.client?.scope == requestScope else { return }
            errorMessage = error.localizedDescription
            sqlNeedsRefresh = (error as? NativeDatabaseClientError)?.requiresSQLReviewBeforeRetry ?? true
        }
    }

    private func rowCard(_ values: [String: JSONValue], title: String) -> some View {
        NativeGroupPanel(title: title, subtitle: "") {
            ForEach(values.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    Text(values[key]?.pretty ?? "null").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(theme.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12, weight: .medium))
    }
}
