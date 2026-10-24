import AppKit
import SwiftUI

struct BackupNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @State private var client: NativeDatabaseClient?
    @State private var dashboard: NativeBackupDashboard?
    @State private var access: NativeDatabaseAccess?
    @State private var selectedFileID = ""
    @State private var archiveSearch = ""
    @State private var archiveDateFilter = ""
    @State private var archiveServiceFilter = ""
    @State private var isLoading = false
    @State private var isOperating = false
    @State private var reviewRequired = false
    @State private var errorMessage = ""
    @State private var operationMessage = ""

    private var selectedFile: NativeBackupFile? { dashboard?.files.first(where: { $0.id == selectedFileID }) }
    private var filteredFiles: [NativeBackupFile] {
        filterNativeBackupFiles(dashboard?.files ?? [], service: archiveServiceFilter, date: archiveDateFilter, search: archiveSearch)
    }
    private var credentialScope: String {
        "\(model.settings.apiBaseURL)|\(model.settings.internalAPIBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.settings.impersonationToken.hashValue)|\(model.settings.impersonatingUserID)|\(model.settings.selectedOrganizationID)"
    }
    private var hasCurrentOperation: Bool { dashboard?.backups.contains(where: { $0.currentOperation != nil }) == true }
    private var writesEnabled: Bool { access?.allowed == true && access?.canEdit == true && !hasCurrentOperation && !isLoading && !isOperating && !reviewRequired && dashboard?.errors.isEmpty == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(isLoading || isOperating)
                ActionButton(title: "Restore drill", icon: "arrow.counterclockwise") {
                    model.openNativeDashboard(path: "/db/restore", label: "Restore drill", query: selectedFile.map { ["file": $0.file] } ?? [:])
                }
                .disabled(dashboard?.files.isEmpty != false)
                Spacer()
                ActionButton(title: isOperating ? "Working…" : "Backup now", icon: "externaldrive.badge.timemachine") { Task { await runBackup() } }
                    .disabled(!writesEnabled)
            }

            if !errorMessage.isEmpty { NativeNotice(message: errorMessage, title: "Backup request failed") }
            if !operationMessage.isEmpty { NativeNotice(message: operationMessage, title: "Backup operation", tone: .success) }
            if reviewRequired {
                NativeNotice(message: "Refresh and review the archive list and operation history before another change. The server may continue an operation after this screen closes.", title: "Review required", tone: .info)
            }
            if isLoading && dashboard == nil { NativeEmptyState(title: "Loading backup information", message: "Checking backup access, archives and recent operations.") }
            if let dashboard {
                ForEach(dashboard.errors, id: \.self) { error in NativeNotice(message: error, title: "Backup data unavailable") }
                if !accessCanEdit {
                    NativeNotice(message: "Backup changes require verified active owner, administrator or editor access. Impersonation is read-only.", title: "Read-only access", tone: .info)
                }
                backupOverview(dashboard)
                archiveSection(dashboard)
                operationHistory(dashboard)
            }
        }
        .task(id: credentialScope) { await refresh() }
    }

    private var accessCanEdit: Bool { access?.allowed == true && access?.canEdit == true }

    @ViewBuilder
    private func backupOverview(_ value: NativeBackupDashboard) -> some View {
        NativeGroupPanel(title: "Backup overview", subtitle: value.backups.first?.database ?? value.backups.first?.name ?? "Configured database") {
            if value.backups.isEmpty {
                Text("No backup services were reported.").font(.system(size: 12))
            }
            ForEach(value.backups) { service in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(service.database ?? service.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(service.currentOperation.map { "\($0.kind) · \($0.status) · \($0.stage)" } ?? service.status.capitalized)
                            .font(.system(size: 11, weight: .semibold)).textSelection(.enabled)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 10) {
                        CompactInfoCard(title: "Last attempt", lines: [formatDateText(service.lastAttempt, fallback: "Never")])
                        CompactInfoCard(title: "Last success", lines: [formatDateText(service.lastSuccess, fallback: "Never")])
                        CompactInfoCard(title: "Last failure", lines: [formatDateText(service.lastFailure, fallback: "Never"), service.lastError ?? ""])
                        CompactInfoCard(title: "Next automatic run", lines: [service.scheduleEnabled == false ? "Paused" : formatDateText(service.nextBackup, fallback: "Not scheduled"), service.schedule.map { "\($0) \(service.scheduleTimezone ?? "UTC")" } ?? ""])
                        CompactInfoCard(title: "Storage target", lines: [service.storageTarget ?? "Not reported"])
                        CompactInfoCard(title: "Retention", lines: [service.retention ?? "Not reported"])
                        if let outcome = service.retentionOutcome {
                            CompactInfoCard(title: "Retention result", lines: ["\(outcome.examined) examined · \(outcome.deleted) deleted", "Cutoff \(formatDateText(outcome.cutoffAt, fallback: outcome.cutoffAt))"])
                        }
                        CompactInfoCard(title: "Latest archive", lines: [service.latestFile ?? "Not recorded", service.latestSize ?? "Size unavailable", service.latestDuration ?? "Duration unavailable"])
                        CompactInfoCard(title: "Latest checksum", lines: [service.latestChecksum ?? "Not recorded", service.latestVerifiedAt.map { "Verified \(formatDateText($0, fallback: $0))" } ?? "No verification metadata"])
                    }
                    if let operation = service.currentOperation {
                        NativeNotice(message: "\(operation.kind) is \(operation.status): \(operation.stage). Started \(formatDateText(operation.startedAt, fallback: operation.startedAt)). Refresh to follow progress.", title: "Operation in progress", tone: .info)
                    }
                    if let message = service.error ?? service.lastError, !message.isEmpty {
                        NativeNotice(message: message, title: "Service report")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func archiveSection(_ value: NativeBackupDashboard) -> some View {
        NativeGroupPanel(title: "Available backups", subtitle: "\(filteredFiles.count) of \(value.files.count) archives · \(value.backups.first?.storageTarget ?? "configured storage")") {
            if value.files.isEmpty {
                Text("No archive exists. Run the first verified backup.").font(.system(size: 12))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .top)], alignment: .leading, spacing: 10) {
                    TextField("Search archive names", text: $archiveSearch)
                        .textFieldStyle(.roundedBorder)
                    TextField("Date filter (YYYY-MM-DD)", text: $archiveDateFilter)
                        .textFieldStyle(.roundedBorder)
                    Picker("Service", selection: $archiveServiceFilter) {
                        Text("All services").tag("")
                        ForEach(Array(Set(value.files.map(\.service))).sorted(), id: \.self) { service in
                            Text(service).tag(service)
                        }
                    }
                }
                if filteredFiles.isEmpty {
                    Text("No archives match these filters.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Picker("Archive", selection: $selectedFileID) {
                        ForEach(filteredFiles) { file in
                            Text("\(file.file) · \(file.size ?? "size unknown") · \(file.verified ? "verified" : "unverified")").tag(file.id)
                        }
                    }
                    if let file = filteredFiles.first(where: { $0.id == selectedFileID }) {
                        HStack(spacing: 10) {
                            FeatureCard(title: "Created", value: formatDateText(file.mtime, fallback: "Unknown"), icon: "calendar")
                            FeatureCard(title: "Size", value: file.size ?? "Unavailable", icon: "externaldrive")
                            FeatureCard(title: "Verification", value: file.verified ? "Verified" : "Unverified", icon: file.verified ? "checkmark.shield" : "exclamationmark.shield")
                        }
                        CompactInfoCard(title: "Checksum", lines: [file.checksumSha256 ?? "Not recorded", file.verifiedAt.map { "Verified \(formatDateText($0, fallback: $0))" } ?? ""])
                        HStack(spacing: 10) {
                            ActionButton(title: "Verify archive", icon: "checkmark.shield") { Task { await runFileAction(.verify, file: file) } }
                                .disabled(!writesEnabled)
                            ActionButton(title: "Delete archive", icon: "trash", tone: .danger) { confirmDelete(file) }
                                .disabled(!writesEnabled)
                            ActionButton(title: "Restore drill", icon: "arrow.counterclockwise") {
                                model.openNativeDashboard(path: "/db/restore", label: "Restore drill", query: ["file": file.file])
                            }
                            .disabled(!writesEnabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func operationHistory(_ value: NativeBackupDashboard) -> some View {
        NativeGroupPanel(title: "Backup operation history", subtitle: "Recent backup, verification, deletion and restore-drill results") {
            let operations = value.backups.flatMap(\.operations).sorted { $0.startedAt > $1.startedAt }
            if operations.isEmpty {
                Text("No backup operations have been recorded.").font(.system(size: 12))
            } else {
                ForEach(operations) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(operation.kind.replacingOccurrences(of: "_", with: " ").capitalized) · \(operation.status.capitalized) · \(operation.stage)")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(formatDateText(operation.startedAt, fallback: operation.startedAt)) · \(operation.file ?? operation.targetDatabase ?? "No archive recorded")")
                            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        if let error = operation.error, !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private enum FileAction: Equatable { case verify, delete }

    private func confirmDelete(_ file: NativeBackupFile) {
        let alert = NSAlert()
        alert.messageText = "Delete backup archive?"
        alert.informativeText = "Permanently delete \(file.file) and its verification metadata? This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await runFileAction(.delete, file: file) }
    }

    private func runFileAction(_ action: FileAction, file: NativeBackupFile) async {
        guard let client, let access, let dashboard else { return }
        isOperating = true
        errorMessage = ""
        operationMessage = ""
        defer { isOperating = false }
        do {
            let result = try await (action == .verify
                ? client.verifyBackup(file, access: access, dashboard: dashboard)
                : client.deleteBackup(file, access: access, dashboard: dashboard))
            operationMessage = "\(result.message) Status: \(result.operation.status). Refresh to review the updated archive list and history."
            reviewRequired = true
        } catch { errorMessage = error.localizedDescription; if (error as? NativeDatabaseClientError)?.requiresSQLReviewBeforeRetry == true { reviewRequired = true } }
    }

    private func runBackup() async {
        guard let client, let access, let dashboard else { return }
        isOperating = true
        errorMessage = ""
        operationMessage = ""
        defer { isOperating = false }
        do {
            let result = try await client.runBackup(access: access, dashboard: dashboard)
            operationMessage = "\(result.message) Status: \(result.operation.status). Refresh to review the updated archive list and history."
            reviewRequired = true
        } catch { errorMessage = error.localizedDescription; if (error as? NativeDatabaseClientError)?.requiresSQLReviewBeforeRetry == true { reviewRequired = true } }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = ""
        reviewRequired = false
        operationMessage = ""
        defer { isLoading = false }
        do {
            let value = try NativeDatabaseClient(settings: model.settings)
            let permissions = try await value.loadAccess()
            guard permissions.allowed else { throw NativeDatabaseClientError.accessDenied }
            let data = try await value.loadBackupDashboard()
            client = value
            access = permissions
            dashboard = data
            selectedFileID = data.files.first(where: { $0.id == selectedFileID })?.id ?? data.files.first?.id ?? ""
        } catch {
            client = nil
            dashboard = nil
            access = nil
            errorMessage = error.localizedDescription
        }
    }
}
