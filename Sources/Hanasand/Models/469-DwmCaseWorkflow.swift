import Foundation

struct DwmCaseWorkflowSnapshot: Equatable {
    let export: [String: IntelligenceCaseJSON]
    let destinations: [IntegrationDestination]
    let deliveries: [[String: IntelligenceCaseJSON]]
    let receiverReceipts: [[String: IntelligenceCaseJSON]]
    let customerNotificationReceipts: [[String: IntelligenceCaseJSON]]
    let organizationID: String?
    let alertID: String?
    let canManageDestinations: Bool
    let liveDeliveryEnabled: Bool
    init(export: [String: IntelligenceCaseJSON], destinations: [IntegrationDestination], deliveries: [[String: IntelligenceCaseJSON]],
         receiverReceipts: [[String: IntelligenceCaseJSON]], customerNotificationReceipts: [[String: IntelligenceCaseJSON]],
         organizationID: String?, alertID: String?, canManageDestinations: Bool, liveDeliveryEnabled: Bool) {
        self.export = export
        self.destinations = destinations
        self.deliveries = deliveries
        self.receiverReceipts = receiverReceipts
        self.customerNotificationReceipts = customerNotificationReceipts
        self.organizationID = organizationID
        self.alertID = alertID
        self.canManageDestinations = canManageDestinations
        self.liveDeliveryEnabled = liveDeliveryEnabled
    }

    var exportChecksum: String { export["exportChecksum"]?.stringValue ?? "" }
    var evidence: [[String: IntelligenceCaseJSON]] { export["evidenceSummary"]?.arrayValue.map(\.objectValue) ?? [] }
    var copyText: String { export["copyText"]?.stringValue ?? "" }

    static func actionBlock(caseDetail: IntelligenceCaseDetailEnvelope, organizationID: String?, selectedEvidenceIDs: [String], destinationID: String) -> String? {
        guard !caseDetail.readOnly else { return "The case is read-only for this session." }
        guard caseDetail.actions.contains(where: { $0.enabled && $0.method.uppercased() == "PATCH" }) else { return "The case policy has no enabled workflow actions." }
        guard let organizationID, !organizationID.isEmpty else { return "Select an organization before creating a third-party report." }
        guard let alertID = caseDetail.alertContext["id"]?.stringValue, !alertID.isEmpty else { return "The case is not linked to an alert." }
        guard !selectedEvidenceIDs.isEmpty else { return "Select at least one evidence row." }
        guard selectedEvidenceIDs.count <= 25, Set(selectedEvidenceIDs).count == selectedEvidenceIDs.count else { return "Select up to 25 unique evidence rows." }
        guard !destinationID.isEmpty else { return "Select a configured destination." }
        return nil
    }
}

enum DwmCaseWorkflowError: LocalizedError, Equatable {
    case signInRequired, organizationRequired, impersonationUnsupported, invalidEndpoint, invalidInput
    case requestFailed(Int), malformedResponse, scopeChanged, uncertainOutcome(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to use DWM case workflows."
        case .organizationRequired: "Select an organization you belong to before using report delivery."
        case .impersonationUnsupported: "Return to your own account to use DWM case workflows."
        case .invalidEndpoint: "DWM case workflows require secure Hanasand endpoints."
        case .invalidInput: "Review the case, evidence, destination, and organization before continuing."
        case .requestFailed(401): "Sign in again to use DWM case workflows."
        case .requestFailed(403): "The server denied this organization workflow."
        case .requestFailed(let code): "DWM case workflow failed (HTTP \(code))."
        case .malformedResponse: "The server response could not be verified. Refresh the case and review."
        case .scopeChanged: "The account or organization changed. Refresh before continuing."
        case .uncertainOutcome(_): "The result is uncertain. Refresh delivery history and receiver receipts before taking another action."
        }
    }
}

struct DwmCaseWorkflowReconciliation: Equatable {
    enum Kind: Equatable { case notification, report, retry }
    let kind: Kind
    let key: String
    let previousAttemptedAt: String?
    let previousAttemptCount: Double

    init(kind: Kind, key: String, previousAttemptedAt: String? = nil, previousAttemptCount: Double = 0) {
        self.kind = kind
        self.key = key
        self.previousAttemptedAt = previousAttemptedAt
        self.previousAttemptCount = previousAttemptCount
    }

    func hasReceipt(in snapshot: DwmCaseWorkflowSnapshot, caseID: String, destinationID: String = "", alertID: String = "") -> Bool {
        switch kind {
        case .notification:
            return snapshot.customerNotificationReceipts.contains { $0["idempotencyKey"]?.stringValue == key }
        case .report:
            return snapshot.deliveries.contains {
                $0["reportCaseId"]?.stringValue == caseID
                    && $0["reportExportChecksum"]?.stringValue == key
                    && $0["destinationId"]?.stringValue == destinationID
                    && $0["alertId"]?.stringValue == alertID
                    && $0["thirdPartyReport"] == .bool(true)
            }
        case .retry:
            return snapshot.deliveries.contains {
                ($0["deliveryId"]?.stringValue ?? $0["id"]?.stringValue) == key
                    && $0["orgId"]?.stringValue == snapshot.organizationID
                    && $0["alertId"]?.stringValue == snapshot.alertID
                    && $0["reportCaseId"]?.stringValue == caseID
                    && $0["thirdPartyReport"] == .bool(true)
                    && ($0["attemptedAt"]?.stringValue != previousAttemptedAt
                        || ($0["attemptCount"]?.numberValue ?? 0) > previousAttemptCount)
            }
        }
    }
}

extension DwmCaseWorkflowSnapshot {
    static func retryBlock(_ delivery: [String: IntelligenceCaseJSON], organizationID: String, caseID: String, alertID: String, now: Date = Date()) -> String? {
        guard delivery["orgId"]?.stringValue == organizationID,
              delivery["reportCaseId"]?.stringValue == caseID,
              delivery["alertId"]?.stringValue == alertID,
              delivery["thirdPartyReport"] == .bool(true),
              delivery["dryRun"] != .bool(true),
              delivery["status"]?.stringValue == "failed",
              delivery["retryable"] == .bool(true),
              delivery["retryDue"] == .bool(true) else { return "This delivery is not eligible for retry." }
        guard let raw = delivery["nextRetryAt"]?.stringValue, let date = ISO8601DateFormatter().date(from: raw) else { return "The server did not provide a valid retry time." }
        return date <= now ? nil : "Retry is available after \(raw)."
    }
}
