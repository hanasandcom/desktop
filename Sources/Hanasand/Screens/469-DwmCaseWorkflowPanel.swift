import AppKit
import SwiftUI

struct DwmCaseWorkflowPanel: View {
    let detail: IntelligenceCaseDetailEnvelope
    let organizationID: String?

    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var snapshot: DwmCaseWorkflowSnapshot?
    @State private var selectedEvidenceIDs = Set<String>()
    @State private var destinationID = ""
    @State private var format = "stix"
    @State private var note = ""
    @State private var pendingLive = false
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var pendingReconciliation: DwmCaseWorkflowReconciliation?
    @State private var pendingRetry: [String: IntelligenceCaseJSON]?
    @State private var error = ""
    @State private var notice = ""
    @State private var noticeIsFailure = false

    private var caseID: String { detail.caseRecord.id }
    private var alertID: String? { detail.alertContext["id"]?.stringValue }
    private var activeDestinations: [IntegrationDestination] { snapshot?.destinations.filter { $0.status == "active" } ?? [] }
    private var blockReason: String? {
        guard let snapshot else { return "Refresh case workflows before creating a report." }
        guard snapshot.canManageDestinations else { return "Destination permissions could not be verified. Delivery actions are unavailable." }
        return DwmCaseWorkflowSnapshot.actionBlock(caseDetail: detail, organizationID: organizationID,
            selectedEvidenceIDs: Array(selectedEvidenceIDs), destinationID: destinationID)
    }
    private var scopeKey: String { "\(model.settings.websiteBaseURL)|\(model.settings.apiBaseURL)|\(model.settings.userID)|\(model.settings.authToken.hashValue)|\(model.selectedOrganizationID)|\(organizationID ?? "")|\(caseID)" }

    var body: some View {
        NativeGroupPanel(title: "DWM case workflows", subtitle: "Exports, notification dry runs, and third-party report delivery") {
            HStack(spacing: 8) {
                ActionButton(title: isLoading ? "Refreshing…" : "Refresh workflow records", icon: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(isLoading || isWriting)
                if !isLoading, let checksum = snapshot?.exportChecksum, !checksum.isEmpty {
                    Text("Export checksum · \(checksum.prefix(16))…").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                }
            }
            if !error.isEmpty { NativeNotice(message: error, title: "DWM workflow unavailable", tone: .error) }
            if !notice.isEmpty { NativeNotice(message: notice, title: noticeIsFailure ? "Delivery failed" : "Workflow record", tone: noticeIsFailure ? .error : .success) }
            if pendingReconciliation != nil {
                NativeNotice(message: "A write may have reached the server. Review refreshed case, delivery, and receiver history before starting another action.", title: "Review the outcome", tone: .info)
            }

            if let snapshot {
                exportSection(snapshot)
                notificationSection
                reportSection(snapshot)
                historySection(snapshot)
            } else if !isLoading && error.isEmpty {
                Text("Refresh to load export and organization workflow records.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
        }
        .task(id: scopeKey) { await refresh() }
        .confirmationDialog("Deliver this report now?", isPresented: $pendingLive, titleVisibility: .visible) {
            Button("Deliver report to \(selectedDestinationName)", role: .destructive) { Task { await sendReport(dryRun: false, confirmedLive: true) } }
            Button("Cancel", role: .cancel) { pendingLive = false }
        } message: {
            Text("Case \(caseID) · alert \(alertID ?? "unlinked") · \(selectedEvidenceIDs.count) evidence rows · \(selectedDestinationName) · \(format.uppercased()). This sends externally and records a delivery receipt.")
        }
        .confirmationDialog("Retry this report delivery?", isPresented: Binding(get: { pendingRetry != nil }, set: { if !$0 { pendingRetry = nil } }), titleVisibility: .visible) {
            Button("Retry recorded delivery", role: .destructive) { let value = pendingRetry; pendingRetry = nil; if let value { Task { await retryReport(value) } } }
            Button("Cancel", role: .cancel) { pendingRetry = nil }
        } message: {
            Text("Retry the exact failed delivery for case \(caseID) and alert \(alertID ?? "unlinked"). The server will record the new attempt.")
        }
    }

    private var selectedDestinationName: String { activeDestinations.first(where: { $0.id == destinationID })?.name ?? "No destination selected" }

    @ViewBuilder private func exportSection(_ value: DwmCaseWorkflowSnapshot) -> some View {
        NativeGroupPanel(title: "Case report export", subtitle: "\(value.evidence.count) evidence rows · checksum \(value.exportChecksum)") {
            if !value.copyText.isEmpty {
                Text(value.copyText).font(.system(size: 11)).foregroundStyle(theme.textSecondary).textSelection(.enabled).lineLimit(8)
                ActionButton(title: "Copy report summary", icon: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value.copyText, forType: .string) }
            }
            if value.evidence.isEmpty { Text("No reportable evidence rows are available.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            ForEach(Array(value.evidence.enumerated()), id: \.offset) { index, row in
                Toggle(isOn: evidenceBinding(row["id"]?.stringValue ?? "")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row["sourceName"]?.stringValue ?? row["title"]?.stringValue ?? "Evidence \(index + 1)").font(.system(size: 11, weight: .medium))
                        Text(row["sourceType"]?.stringValue ?? row["kind"]?.stringValue ?? row["id"]?.stringValue ?? "Evidence metadata").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                    }
                }.disabled(row["id"]?.stringValue.isEmpty != false || selectedEvidenceIDs.count >= 25 && !selectedEvidenceIDs.contains(row["id"]?.stringValue ?? ""))
            }
        }
    }

    private var notificationSection: some View {
        NativeGroupPanel(title: "Customer notification", subtitle: "Dry run only; records a receipt without sending a notification") {
            TextField("Customer-safe note", text: $note, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(isWriting || pendingReconciliation != nil)
            ActionButton(title: isWriting ? "Recording…" : "Record notification dry run", icon: "checkmark.shield") { Task { await notifyDryRun() } }
                .disabled(isWriting || pendingReconciliation != nil || detail.readOnly || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Recorded notifications: \(snapshot?.customerNotificationReceipts.count ?? detail.caseRecord.raw["customerNotifications"]?.arrayValue.count ?? 0)")
                .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder private func reportSection(_ value: DwmCaseWorkflowSnapshot) -> some View {
        NativeGroupPanel(title: "Third-party report", subtitle: "Dry run is the default. Live delivery requires a separate confirmation.") {
            Picker("Format", selection: $format) { Text("STIX 2.1").tag("stix"); Text("Hanasand JSON").tag("json") }.pickerStyle(.segmented).disabled(isWriting || pendingReconciliation != nil)
            Picker("Destination", selection: $destinationID) {
                Text("Select a destination").tag("")
                ForEach(activeDestinations) { Text("\($0.name) · \($0.kind.title)").tag($0.id) }
            }.disabled(isWriting || pendingReconciliation != nil || !value.canManageDestinations)
            Text("Selected \(selectedEvidenceIDs.count) of up to 25 evidence rows · \(alertID ?? "No linked alert")")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            HStack(spacing: 8) {
                ActionButton(title: "Save JSON report", icon: "square.and.arrow.down") { Task { await saveReport(format: "json") } }
                    .disabled(isWriting || pendingReconciliation != nil || selectedEvidenceIDs.isEmpty || alertID == nil)
                ActionButton(title: "Save STIX 2.1 report", icon: "square.and.arrow.down") { Task { await saveReport(format: "stix") } }
                    .disabled(isWriting || pendingReconciliation != nil || selectedEvidenceIDs.isEmpty || alertID == nil)
            }
            if let blockReason { Text(blockReason).font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            if !value.liveDeliveryEnabled { Text("Live delivery is disabled by the current server readiness policy. Dry runs remain available.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            HStack(spacing: 8) {
                ActionButton(title: "Run dry run", icon: "testtube.2") { Task { await sendReport(dryRun: true) } }
                    .disabled(isWriting || pendingReconciliation != nil || blockReason != nil)
                ActionButton(title: "Review live delivery", icon: "paperplane") { pendingLive = true }
                    .disabled(isWriting || pendingReconciliation != nil || blockReason != nil || !value.liveDeliveryEnabled)
            }
        }
    }

    @ViewBuilder private func historySection(_ value: DwmCaseWorkflowSnapshot) -> some View {
        NativeGroupPanel(title: "Delivery and receiver history", subtitle: "\(value.deliveries.count) case report deliveries · \(value.receiverReceipts.count) persisted receiver receipts") {
            if value.deliveries.isEmpty && value.receiverReceipts.isEmpty { Text("No third-party report receipts are recorded for this case.").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
            ForEach(Array(value.deliveries.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text("\(row["status"]?.stringValue ?? row["rawStatus"]?.stringValue ?? "Status not reported") · \(row["deliveryId"]?.stringValue ?? row["id"]?.stringValue ?? row["requestId"]?.stringValue ?? "Receipt ID unavailable") · \(row["attemptedAt"]?.stringValue ?? "time unavailable")")
                        .font(.system(size: 10)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                    Spacer()
                    if let organizationID, let alertID,
                       DwmCaseWorkflowSnapshot.retryBlock(row, organizationID: organizationID, caseID: caseID, alertID: alertID) == nil,
                       value.canManageDestinations, value.liveDeliveryEnabled {
                        ActionButton(title: "Retry", icon: "arrow.clockwise") { pendingRetry = row }
                            .disabled(isWriting || pendingReconciliation != nil)
                    }
                }
            }
            ForEach(Array(value.receiverReceipts.enumerated()), id: \.offset) { _, row in
                Text("Receiver receipt · \(row["id"]?.stringValue ?? "ID unavailable") · \(row["receivedAt"]?.stringValue ?? row["persistedAt"]?.stringValue ?? "time unavailable")")
                    .font(.system(size: 10)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
        }
    }

    private func evidenceBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedEvidenceIDs.contains(id) }, set: { selected in
            if selected { selectedEvidenceIDs.insert(id) } else { selectedEvidenceIDs.remove(id) }
        })
    }

    @MainActor private func saveReport(format: String) async {
        guard let snapshot, let alertID, !selectedEvidenceIDs.isEmpty else { return }
        isWriting = true; error = ""; notice = ""; noticeIsFailure = false
        do {
            let expectedSettings = model.settings
            let client = try DwmCaseWorkflowClient(settings: expectedSettings, organizationIDOverride: organizationID)
            let report = try await client.reportExport(caseID: caseID, evidenceIDs: selectedEvidenceIDs.sorted(), format: format,
                alertID: alertID, caseDetail: detail, snapshot: snapshot, currentSettings: expectedSettings)
            guard expectedSettings == model.settings else { throw DwmCaseWorkflowError.scopeChanged }
            let data = try JSONSerialization.data(withJSONObject: report.mapValues(\.foundationValue), options: [.prettyPrinted, .sortedKeys])
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(safeFilenameComponent(caseID))-\(format)-report.json"
            guard panel.runModal() == .OK, let url = panel.url else {
                notice = "Report export cancelled."
                isWriting = false
                return
            }
            try data.write(to: url, options: .atomic)
            notice = "\(format.uppercased()) report saved to \(url.lastPathComponent)."
        } catch {
            self.error = error.localizedDescription
        }
        isWriting = false
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let cleaned = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        return String(cleaned.prefix(100))
    }

    @MainActor private func refresh() async {
        guard !isLoading else { return }
        isLoading = true; error = ""; notice = ""; noticeIsFailure = false
        do {
            let client = try DwmCaseWorkflowClient(settings: model.settings, organizationIDOverride: organizationID)
            let current = model.settings
            let value = try await client.load(caseID: caseID, alertID: alertID)
            guard current == model.settings else { throw DwmCaseWorkflowError.scopeChanged }
            snapshot = value
            selectedEvidenceIDs = selectedEvidenceIDs.filter { id in value.evidence.contains { $0["id"]?.stringValue == id } }
            if !value.destinations.contains(where: { $0.id == destinationID && $0.status == "active" }) { destinationID = "" }
            if let pending = pendingReconciliation,
               pending.hasReceipt(in: value, caseID: caseID, destinationID: destinationID, alertID: alertID ?? "") {
                pendingReconciliation = nil
                notice = "The refreshed history contains the matching durable receipt. Review it before continuing."
            }
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    @MainActor private func notifyDryRun() async {
        isWriting = true; error = ""; notice = ""; noticeIsFailure = false
        do {
            let expectedSettings = model.settings
            let client = try DwmCaseWorkflowClient(settings: expectedSettings, organizationIDOverride: organizationID)
            let receipt = try await client.notifyCustomerDryRun(caseID: caseID, note: note, currentSettings: expectedSettings, caseDetail: detail,
                scopeIsCurrent: { expectedSettings == model.settings })
            notice = "Notification dry run recorded · receipt \(receipt["id"]?.stringValue ?? "verified")"
            note = ""
            await refresh()
        } catch {
            self.error = error.localizedDescription
            if let workflowError = error as? DwmCaseWorkflowError, case let .uncertainOutcome(key) = workflowError {
                pendingReconciliation = DwmCaseWorkflowReconciliation(kind: .notification, key: key)
                await refresh()
            }
        }
        isWriting = false
    }

    @MainActor private func sendReport(dryRun: Bool, confirmedLive: Bool = false) async {
        guard let alertID, blockReason == nil else { return }
        isWriting = true; error = ""; notice = ""; noticeIsFailure = false
        do {
            let expectedSettings = model.settings
            let client = try DwmCaseWorkflowClient(settings: expectedSettings, organizationIDOverride: organizationID)
            let receipt = try await client.deliverReport(caseID: caseID, evidenceIDs: Array(selectedEvidenceIDs), format: format,
                destinationID: destinationID, alertID: alertID, dryRun: dryRun, confirmedLive: confirmedLive,
                caseDetail: detail, currentSettings: expectedSettings,
                scopeIsCurrent: { expectedSettings == model.settings })
            await refresh()
            if receipt["status"]?.stringValue == "failed" {
                notice = "The failed attempt was recorded. Review delivery history and its retry time before trying again."
                noticeIsFailure = true
            } else {
                notice = "\(dryRun ? "Dry run" : "Delivery") recorded · \(receipt["status"]?.stringValue ?? "receipt verified")"
            }
        } catch {
            self.error = error.localizedDescription
            if let workflowError = error as? DwmCaseWorkflowError, case let .uncertainOutcome(key) = workflowError {
                pendingReconciliation = DwmCaseWorkflowReconciliation(kind: .report, key: key)
                await refresh()
            }
        }
        isWriting = false
    }

    @MainActor private func retryReport(_ delivery: [String: IntelligenceCaseJSON]) async {
        guard let alertID, let organizationID else { return }
        let previousAt = delivery["attemptedAt"]?.stringValue
        let previousCount = delivery["attemptCount"]?.numberValue ?? 0
        isWriting = true; error = ""; notice = ""; noticeIsFailure = false
        do {
            let expectedSettings = model.settings
            let client = try DwmCaseWorkflowClient(settings: expectedSettings, organizationIDOverride: organizationID)
            let receipt = try await client.retryReport(delivery: delivery, caseID: caseID, alertID: alertID, currentSettings: expectedSettings,
                scopeIsCurrent: { expectedSettings == model.settings })
            await refresh()
            if receipt["status"]?.stringValue == "failed" {
                notice = "The retry failure was recorded. Review delivery history and its retry time before trying again."
                noticeIsFailure = true
            } else {
                notice = "Retry receipt confirmed · \(receipt["status"]?.stringValue ?? "status unavailable")"
            }
        } catch {
            self.error = error.localizedDescription
            if let workflowError = error as? DwmCaseWorkflowError, case let .uncertainOutcome(key) = workflowError {
                pendingReconciliation = DwmCaseWorkflowReconciliation(kind: .retry, key: key, previousAttemptedAt: previousAt, previousAttemptCount: previousCount)
                await refresh()
            }
        }
        isWriting = false
    }
}
