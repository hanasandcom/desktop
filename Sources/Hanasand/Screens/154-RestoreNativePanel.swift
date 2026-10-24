import SwiftUI

struct RestoreNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @State private var client: NativeDatabaseClient?
    @State private var dashboard: NativeBackupDashboard?
    @State private var access: NativeDatabaseAccess?
    @State private var selectedFileID = ""
    @State private var didChooseArchive = false
    @State private var targetDatabase = Self.defaultTarget
    @State private var confirmation = ""
    @State private var operationResult: NativeBackupOperation?
    @State private var isLoading = false
    @State private var isOperating = false
    @State private var reviewRequired = false
    @State private var errorMessage = ""
    @State private var operationMessage = ""

    private static var defaultTarget: String { "restore_drill_" + ISO8601DateFormatter().string(from: Date()).prefix(10).replacingOccurrences(of: "-", with: "") }
    private var selectedFile: NativeBackupFile? { dashboard?.files.first(where: { $0.id == selectedFileID }) }
    private var activeDrill: NativeBackupOperation? { dashboard?.backups.compactMap(\.currentOperation).first(where: { $0.kind == "restore_drill" }) }
    private var activeOperation: NativeBackupOperation? { dashboard?.backups.compactMap(\.currentOperation).first }
    private var trackedRestoreOperation: NativeBackupOperation? {
        guard let operationResult else { return nil }
        return dashboard.flatMap { backupOperation(withID: operationResult.id, in: $0) } ?? operationResult
    }
    private var restoreOperation: NativeBackupOperation? {
        let expectedKind = isLiveRestore ? "restore_live" : "restore_drill"
        if let trackedRestoreOperation, trackedRestoreOperation.kind == expectedKind { return trackedRestoreOperation }
        return dashboard?.backups.compactMap(\.currentOperation).first(where: { $0.kind == expectedKind })
    }
    private var shouldRefreshOperation: Bool {
        shouldRefreshBackupOperation(currentOperation: activeOperation, trackedOperation: trackedRestoreOperation)
    }
    private var isLiveRestore: Bool { model.selectedNativeDashboardQuery["mode"] == "live" }
    private var liveDatabase: String { dashboard?.backups.first?.database ?? "" }
    private var drillHistory: [NativeBackupOperation] { (dashboard?.backups.flatMap(\.operations) ?? []).filter { $0.kind == "restore_drill" }.sorted { $0.startedAt > $1.startedAt } }
    private var credentialScope: String {
        "\(model.settings.apiBaseURL)|\(model.settings.internalAPIBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(model.settings.selectedOrganizationID)"
    }
    private var canRun: Bool {
        access?.allowed == true && access?.canEdit == true && selectedFile != nil &&
        (isLiveRestore ? (!liveDatabase.isEmpty && confirmation == "RESTORE \(liveDatabase)") :
            (targetDatabase.range(of: "^restore_drill_[a-z0-9_]{1,48}$", options: .regularExpression) != nil && confirmation == "RESTORE \(targetDatabase)")) &&
            !isLoading && !isOperating && !reviewRequired && activeOperation == nil &&
            dashboard?.errors.isEmpty == true && dashboard?.backups.contains(where: { $0.currentOperation != nil }) == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), alignment: .leading)], alignment: .leading, spacing: 10) {
                ActionButton(title: isLoading ? "Refreshing…" : "Refresh files", icon: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(isLoading || isOperating)
                ActionButton(title: "Back to backups", icon: "externaldrive.badge.timemachine") {
                    model.openNativeDashboard(path: "/db/backups", label: "Backups")
                }
                ActionButton(title: isLiveRestore ? "Isolated restore drill" : "Restore live database", icon: isLiveRestore ? "checkmark.shield" : "exclamationmark.triangle") {
                    var query: [String: String] = isLiveRestore ? [:] : ["mode": "live"]
                    if let file = selectedFile { query["file"] = file.file }
                    model.openNativeDashboard(path: "/db/restore", label: isLiveRestore ? "Restore drill" : "Restore live database", query: query)
                    confirmation = ""
                }
            }
            if !errorMessage.isEmpty { NativeNotice(message: errorMessage, title: "Restore drill request failed") }
            if !operationMessage.isEmpty { NativeNotice(message: operationMessage, title: isLiveRestore ? "Live restore" : "Restore drill", tone: .success) }
            if reviewRequired {
                NativeNotice(message: "Refresh and review the current archives and operation history before another submission. Server operations may continue after this screen closes.", title: "Review required", tone: .info)
            }
            if isLoading && dashboard == nil {
                NativeEmptyState(title: "Loading restore candidates", message: "Checking access, archives and operation history.")
            }
            if let dashboard {
                ForEach(dashboard.errors, id: \.self) { error in NativeNotice(message: error, title: "Backup data unavailable") }
                if let requestedFile = model.selectedNativeDashboardQuery["file"], !didChooseArchive,
                   dashboard.files.first(where: { $0.file == requestedFile }) == nil {
                    NativeNotice(message: "The requested archive is no longer available. Choose an archive from the current list before restoring.", title: "Archive unavailable", tone: .info)
                }
                if access?.allowed != true || access?.canEdit != true {
                    NativeNotice(message: "Restore operations require verified active owner, administrator or editor access. Impersonation is read-only.", title: "Read-only access", tone: .info)
                }
                drillControls(dashboard)
                if let operation = restoreOperation { operationProgress(operation) }
                drillHistoryPanel
            }
        }
        .task(id: "\(credentialScope)|\(model.selectedNativeDashboardQuery["file"] ?? "")") {
            client = nil
            dashboard = nil
            access = nil
            operationResult = nil
            didChooseArchive = false
            await refresh()
        }
        .task(id: activeOperation?.id ?? operationResult?.id) { await refreshWhileOperationRuns() }
    }

    @ViewBuilder
    private func drillControls(_ value: NativeBackupDashboard) -> some View {
        NativeGroupPanel(title: isLiveRestore ? "Restore live database" : "Isolated restore drill", subtitle: isLiveRestore ? "Replace all live database data with the selected archive." : "Restore into a temporary database, check its table shape, and remove the temporary target.") {
            NativeNotice(message: isLiveRestore
                ? "This replaces all data in \(liveDatabase.isEmpty ? "the live database" : liveDatabase). Requests may briefly fail while the database switches. Choose the archive carefully and type the exact confirmation."
                : "This workflow never restores over the live database. The API requires a restore_drill_ target and rejects the live database name.", title: isLiveRestore ? "Destructive operation" : "Live database protection", tone: .info)
            if value.files.isEmpty {
                Text("No backup archive is available. Refresh after an archive is reported.").font(.system(size: 12))
            } else {
                Picker("Backup archive", selection: Binding(
                    get: { selectedFileID },
                    set: { selectedFileID = $0; didChooseArchive = true }
                )) {
                    ForEach(value.files) { file in
                        Text("\(file.file) · \(file.size ?? "size unknown") · \(file.verified ? "verified" : "verify during drill")").tag(file.id)
                    }
                }
                if let file = selectedFile {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 10) {
                        FeatureCard(title: "Measured file", value: file.size ?? "Not reported", icon: "externaldrive")
                        FeatureCard(title: "Verification", value: file.verified ? "Verified" : "Checked during drill", icon: "checkmark.shield")
                        FeatureCard(title: "Release commit", value: String(file.releaseCommit?.prefix(12) ?? "Not reported"), icon: "number")
                    }
                    CompactInfoCard(title: "Checksum", lines: [file.checksumSha256 ?? "Verified during drill"])
                }
                if !isLiveRestore {
                    TextField("Isolated target database", text: $targetDatabase)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: targetDatabase) { _, value in targetDatabase = value.lowercased(); confirmation = "" }
                    Text("Use lowercase letters, numbers and underscores. Target must start with restore_drill_.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    fact("Live database", liveDatabase.isEmpty ? "Unavailable" : liveDatabase)
                }
                TextField("Type RESTORE \(isLiveRestore ? liveDatabase : targetDatabase) to confirm", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                ActionButton(title: activeOperation.map { "\($0.stage.replacingOccurrences(of: "_", with: " ").capitalized)…" } ?? (isOperating ? "Starting restore…" : (isLiveRestore ? "Restore live database" : "Run isolated restore drill")), icon: isLiveRestore ? "exclamationmark.triangle" : "checkmark.shield", tone: isLiveRestore ? .danger : .normal) {
                    confirmRestore()
                }
                .disabled(!canRun)
            }
        }
    }

    @ViewBuilder
    private func operationProgress(_ operation: NativeBackupOperation) -> some View {
        NativeGroupPanel(title: isLiveRestore ? "Live restore progress" : "Current drill evidence", subtitle: "\(operation.status.capitalized) · \(operation.stage.replacingOccurrences(of: "_", with: " "))") {
            fact("Started", formatDateText(operation.startedAt, fallback: operation.startedAt))
            fact("Archive", operation.file ?? "Unavailable")
            fact("Target", operation.targetDatabase ?? "Unavailable")
            if let restored = operation.restoredIntegrity {
                fact("Restored integrity", "\(restored.schemas) schemas · \(restored.tables) tables · \(restored.estimatedRows.map(String.init) ?? "row count unavailable") rows")
            }
            if let source = operation.sourceIntegrity { fact("Source integrity", "\(source.schemas) schemas · \(source.tables) tables") }
            if let removed = operation.targetRemoved { fact("Temporary target removed", removed ? "Yes" : "No") }
            if let error = operation.error, !error.isEmpty { NativeNotice(message: error, title: "Drill result") }
        }
    }

    private var drillHistoryPanel: some View {
        NativeGroupPanel(title: "Restore-drill audit history", subtitle: "Recorded isolated restore results") {
            if drillHistory.isEmpty {
                Text("No isolated restore drill has been attempted yet.").font(.system(size: 12))
            } else {
                ForEach(drillHistory) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(formatDateText(operation.startedAt, fallback: operation.startedAt)) · \(operation.targetDatabase ?? "Unknown target") · \(operation.status.capitalized)")
                            .font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                        Text(operation.error ?? integritySummary(operation)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func runDrill() async {
        guard let client, let access, let dashboard, let file = selectedFile else { return }
        isOperating = true
        errorMessage = ""
        operationMessage = ""
        defer { isOperating = false }
        do {
            let result = try await (isLiveRestore
                ? client.runLiveRestore(file, confirmation: confirmation, access: access, dashboard: dashboard)
                : client.runRestoreDrill(file, targetDatabase: targetDatabase, confirmation: confirmation, access: access, dashboard: dashboard))
            operationMessage = "\(result.message) Status: \(result.operation.status)."
            operationResult = result.operation
            reviewRequired = true
            confirmation = ""
            await refresh(isBackground: true)
        } catch {
            errorMessage = error.localizedDescription
            if (error as? NativeDatabaseClientError)?.requiresSQLReviewBeforeRetry == true { reviewRequired = true }
        }
    }

    private func confirmRestore() {
        guard let file = selectedFile else { return }
        let alert = NSAlert()
        alert.messageText = isLiveRestore ? "Restore the live database?" : "Run isolated restore drill?"
        alert.informativeText = isLiveRestore
            ? "Replace all data in \(liveDatabase) with \(file.file). Database requests may briefly fail while it switches. This cannot be undone."
            : "Restore \(file.file) into temporary database \(targetDatabase), check its table shape, and remove the temporary target."
        alert.alertStyle = isLiveRestore ? .critical : .informational
        alert.addButton(withTitle: isLiveRestore ? "Restore live database" : "Run restore drill")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await runDrill() }
    }

    private func refreshWhileOperationRuns() async {
        guard shouldRefreshOperation else { return }
        while !Task.isCancelled, shouldRefreshOperation {
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            await refresh(isBackground: true)
        }
    }

    private func refresh(isBackground: Bool = false) async {
        if !isBackground {
            isLoading = true
            errorMessage = ""
            operationMessage = ""
            reviewRequired = false
        } else {
            errorMessage = ""
        }
        defer { if !isBackground { isLoading = false } }
        do {
            let value = try NativeDatabaseClient(settings: model.settings)
            let permissions = try await value.loadAccess()
            guard permissions.allowed else { throw NativeDatabaseClientError.accessDenied }
            let data = try await value.loadBackupDashboard()
            client = value
            access = permissions
            dashboard = data
            selectedFileID = preferredNativeRestoreFileID(
                files: data.files,
                requestedFile: model.selectedNativeDashboardQuery["file"],
                currentFileID: selectedFileID,
                didChooseArchive: didChooseArchive
            )
            if let operationResult,
               let refreshed = backupOperation(withID: operationResult.id, in: data) {
                self.operationResult = refreshed
                if refreshed.status.lowercased() != "running" { reviewRequired = false }
            }
        } catch {
            errorMessage = error.localizedDescription
            if !isBackground {
                client = nil
                dashboard = nil
                access = nil
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .font(.system(size: 12))
    }

    private func integritySummary(_ operation: NativeBackupOperation) -> String {
        guard let restored = operation.restoredIntegrity else { return operation.stage.replacingOccurrences(of: "_", with: " ").capitalized }
        let matches = operation.sourceIntegrity?.tables == restored.tables ? "passed" : "unavailable"
        return "\(restored.schemas) schemas, \(restored.tables) tables, source match \(matches). Temporary target removed: \(operation.targetRemoved == true ? "yes" : "no")."
    }
}

func preferredNativeRestoreFileID(files: [NativeBackupFile], requestedFile: String?, currentFileID: String, didChooseArchive: Bool) -> String {
    if !didChooseArchive, let requestedFile {
        return files.first(where: { $0.file == requestedFile })?.id ?? ""
    }
    return files.first(where: { $0.id == currentFileID })?.id ?? files.first?.id ?? ""
}
