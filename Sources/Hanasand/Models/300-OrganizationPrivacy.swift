import Foundation

struct OrganizationPrivacySnapshot: Decodable, Equatable {
    let schemaVersion: String
    let organization: Organization
    let runs: [Record]
    let requests: [Record]
    let items: [Record]
    let itemPage: Page
    let protection: Protection
    let permissions: Permissions?

    struct Organization: Decodable, Equatable {
        let id: String
        let name: String
        let status: String
        let retentionDays: Int

        enum CodingKeys: String, CodingKey {
            case id, name, status
            case retentionDays = "retention_days"
        }
    }

    struct Page: Decodable, Equatable {
        let offset: Int
        let limit: Int
        let nextOffset: Int?

        enum CodingKeys: String, CodingKey { case offset, limit, nextOffset }
    }

    struct Permissions: Decodable, Equatable {
        let canExport: Bool
        let canRunRetention: Bool
        let canRequestDeletion: Bool
        let deletionRequiresReauthentication: Bool

        func allows(_ action: OrganizationPrivacyAction) -> Bool {
            switch action {
            case .export: canExport
            case .runRetention: canRunRetention
            case .delete: canRequestDeletion && deletionRequiresReauthentication
            }
        }
    }

    struct Protection: Decodable, Equatable {
        let protectedEvents: Int
        let totalRetentionItems: Int
        let accessRecoveryHolds: Int
        let immutableSystemEvents: Int
        let immutableWebhookAuditEvents: Int
        let immutableLogEvents: Int
        let explanation: String

        enum CodingKeys: String, CodingKey {
            case protectedEvents = "protected_events"
            case totalRetentionItems = "total_retention_items"
            case accessRecoveryHolds = "access_recovery_holds"
            case immutableSystemEvents = "immutable_system_events"
            case immutableWebhookAuditEvents = "immutable_webhook_audit_events"
            case immutableLogEvents = "immutable_log_events"
            case explanation
        }
    }

    struct Record: Decodable, Equatable, Identifiable {
        let storedID: String?
        let organizationID: String
        let runID: String?
        let sourceService: String?
        let recordType: String?
        let recordID: String?
        let status: String?
        let requestID: String?
        let requestType: String?
        let triggerType: String?
        let createdAt: String?
        let requestedAt: String?
        let completedAt: String?
        let processedAt: String?
        let cutoffAt: String?
        let selectedCount: Int?
        let deletedCount: Int?
        let redactedCount: Int?
        let protectedCount: Int?
        let failedCount: Int?
        let retriedCount: Int?
        let attemptCount: Int?
        let nextRetryAt: String?
        let requestedBy: String?
        let privacyRequestID: String?
        let error: String?
        let reason: String?

        var id: String {
            storedID ?? [runID, sourceService, recordType, recordID].compactMap { $0 }.joined(separator: ":")
        }

        enum CodingKeys: String, CodingKey {
            case id, status, error, reason
            case organizationID = "organization_id"
            case runID = "run_id"
            case sourceService = "source_service"
            case recordType = "record_type"
            case recordID = "record_id"
            case requestID = "request_id"
            case requestType = "request_type"
            case triggerType = "trigger_type"
            case createdAt = "created_at"
            case requestedAt = "requested_at"
            case completedAt = "completed_at"
            case processedAt = "processed_at"
            case cutoffAt = "cutoff_at"
            case selectedCount = "selected_count"
            case deletedCount = "deleted_count"
            case redactedCount = "redacted_count"
            case protectedCount = "protected_count"
            case failedCount = "failed_count"
            case retriedCount = "retried_count"
            case attemptCount = "attempt_count"
            case nextRetryAt = "next_retry_at"
            case requestedBy = "requested_by"
            case privacyRequestID = "privacy_request_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            storedID = try c.decodeIfPresent(String.self, forKey: .id)
            organizationID = try c.decode(String.self, forKey: .organizationID)
            runID = try c.decodeIfPresent(String.self, forKey: .runID)
            sourceService = try c.decodeIfPresent(String.self, forKey: .sourceService)
            recordType = try c.decodeIfPresent(String.self, forKey: .recordType)
            recordID = try c.decodeIfPresent(String.self, forKey: .recordID)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
            requestType = try c.decodeIfPresent(String.self, forKey: .requestType)
            triggerType = try c.decodeIfPresent(String.self, forKey: .triggerType)
            createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            requestedAt = try c.decodeIfPresent(String.self, forKey: .requestedAt)
            completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
            processedAt = try c.decodeIfPresent(String.self, forKey: .processedAt)
            cutoffAt = try c.decodeIfPresent(String.self, forKey: .cutoffAt)
            selectedCount = try c.decodeIfPresent(Int.self, forKey: .selectedCount)
            deletedCount = try c.decodeIfPresent(Int.self, forKey: .deletedCount)
            redactedCount = try c.decodeIfPresent(Int.self, forKey: .redactedCount)
            protectedCount = try c.decodeIfPresent(Int.self, forKey: .protectedCount)
            failedCount = try c.decodeIfPresent(Int.self, forKey: .failedCount)
            retriedCount = try c.decodeIfPresent(Int.self, forKey: .retriedCount)
            attemptCount = try c.decodeIfPresent(Int.self, forKey: .attemptCount)
            nextRetryAt = try c.decodeIfPresent(String.self, forKey: .nextRetryAt)
            requestedBy = try c.decodeIfPresent(String.self, forKey: .requestedBy)
            privacyRequestID = try c.decodeIfPresent(String.self, forKey: .privacyRequestID)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            guard !(storedID ?? "").isEmpty || ![runID, sourceService, recordType, recordID].compactMap({ $0 }).isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Privacy record has no stable identifier")
            }
        }
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, organization, runs, requests, items, protection, permissions; case itemPage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
        organization = try c.decode(Organization.self, forKey: .organization)
        runs = try c.decode([Record].self, forKey: .runs)
        requests = try c.decode([Record].self, forKey: .requests)
        items = try c.decode([Record].self, forKey: .items)
        itemPage = try c.decode(Page.self, forKey: .itemPage)
        protection = try c.decode(Protection.self, forKey: .protection)
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions)
    }

    func validate(organizationID: String, requestedOffset: Int, requirePermissions: Bool = true, expectedLimit: Int = 50) throws {
        guard schemaVersion == "organization.privacy_state.v1",
              organization.id == organizationID, !organization.name.isEmpty,
              organization.retentionDays >= 0,
              itemPage.offset == requestedOffset, itemPage.limit == expectedLimit,
              itemPage.nextOffset == nil || itemPage.nextOffset! > itemPage.offset,
              items.count <= itemPage.limit,
              [runs, requests, items].flatMap({ $0 }).allSatisfy({ $0.organizationID == organizationID && !$0.id.isEmpty }),
              Set(runs.map(\.id)).count == runs.count,
              Set(requests.map(\.id)).count == requests.count,
              [protection.protectedEvents, protection.totalRetentionItems, protection.accessRecoveryHolds,
               protection.immutableSystemEvents, protection.immutableWebhookAuditEvents, protection.immutableLogEvents].allSatisfy({ $0 >= 0 }),
              !requirePermissions || permissions != nil
        else { throw OrganizationPrivacyError.invalidResponse }
    }
}

enum OrganizationPrivacyAction: String, Codable, CaseIterable, Identifiable {
    case export
    case runRetention = "run_retention"
    case delete

    var id: String { rawValue }
    var title: String {
        switch self {
        case .export: "Export data"
        case .runRetention: "Run purge now"
        case .delete: "Request deletion"
        }
    }
    var buttonTitle: String {
        switch self {
        case .export, .runRetention: "Continue"
        case .delete: "Request deletion"
        }
    }
    var isDestructive: Bool { self == .delete }
    func message(organization: String, retentionDays: Int) -> String {
        switch self {
        case .export: "Create a privacy request and prepare a file containing sensitive data for \(organization)."
        case .runRetention: "Purge eligible data older than \(retentionDays) days for \(organization). Protected records remain."
        case .delete: "Delete eligible data for \(organization). Protected evidence remains. Access to the organization may be removed."
        }
    }
}

struct OrganizationPrivacyIntent: Equatable {
    let action: OrganizationPrivacyAction
    let requestID: String
}

enum OrganizationPrivacyReconciliation {
    static func matchingRecord(in state: OrganizationPrivacySnapshot, intent: OrganizationPrivacyIntent) -> OrganizationPrivacySnapshot.Record? {
        let statuses = ["queued", "running", "completed", "failed", "dead_letter"]
        let record: OrganizationPrivacySnapshot.Record?
        switch intent.action {
        case .export:
            record = state.requests.first { $0.requestID == intent.requestID && $0.requestType == "export" }
        case .runRetention:
            record = state.runs.first { $0.requestID == intent.requestID && $0.triggerType == "manual" }
        case .delete:
            guard let request = state.requests.first(where: { $0.requestID == intent.requestID && $0.requestType == "deletion" }) else { return nil }
            if request.status == "failed" { return request }
            record = state.runs.first { $0.requestID == intent.requestID && $0.triggerType == "privacy_deletion" && $0.privacyRequestID == request.id }
        }
        guard let record, let status = record.status, statuses.contains(status) else { return nil }
        return record
    }
}

indirect enum OrganizationPrivacyJSON: Decodable, Equatable {
    case object([String: OrganizationPrivacyJSON])
    case array([OrganizationPrivacyJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([OrganizationPrivacyJSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: OrganizationPrivacyJSON].self) { self = .object(value) }
        else { throw OrganizationPrivacyError.invalidResponse }
    }

    subscript(_ key: String) -> OrganizationPrivacyJSON? {
        guard case let .object(values) = self else { return nil }
        return values[key]
    }
    var stringValue: String? { if case let .string(value) = self { value } else { nil } }
}

struct OrganizationPrivacyExport: Decodable, Equatable {
    let schemaVersion: String
    let organizationID: String
    let tenantID: String
    let exportedAt: String
    let data: OrganizationPrivacyJSON
    let checksum: String

    enum CodingKeys: String, CodingKey { case schemaVersion, organizationID, tenantID, exportedAt, data, checksum }

    func validate(organizationID expectedID: String) throws {
        guard schemaVersion == "organization.privacy_export.v1",
              organizationID == expectedID, tenantID == expectedID,
              ISO8601DateFormatter().date(from: exportedAt) != nil,
              checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              data["public"]?["organization"]?["id"]?.stringValue == expectedID,
              data["threatIntelligence"]?["schemaVersion"]?.stringValue == "organization.privacy_export.ti.v1",
              data["threatIntelligence"]?["organizationId"]?.stringValue == expectedID,
              data["threatIntelligence"]?["tenantId"]?.stringValue == expectedID else {
            throw OrganizationPrivacyError.unconfirmedOutcome
        }
    }
}

struct OrganizationPrivacyActionReceipt {
    let action: OrganizationPrivacyAction
    let requestID: String
    let status: String
    let state: OrganizationPrivacySnapshot?
    let exportFile: Data?
    let checksum: String?
    let serverRecordID: String?
}

enum OrganizationPrivacyError: LocalizedError {
    case invalidBaseURL
    case signInRequired
    case invalidCredentials
    case impersonationUnsupported
    case organizationScopeChanged
    case invalidOffset
    case invalidResponse
    case invalidAction
    case permissionDenied
    case invalidDeletionConfirmation
    case duplicateSubmission
    case unconfirmedOutcome
    case uncertainOutcome(String)
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Organization Privacy requires a secure API URL."
        case .signInRequired: return "Sign in to view organization privacy."
        case .invalidCredentials: return "The current account credentials are invalid. Sign in again."
        case .impersonationUnsupported: return "Return to your own account to view organization privacy."
        case .organizationScopeChanged: return "Organization access changed. Refresh the organization directory."
        case .invalidOffset: return "Choose a valid privacy history page."
        case .invalidResponse: return "The organization privacy response was invalid or did not match the selected organization."
        case .invalidAction: return "Choose a valid organization privacy action."
        case .permissionDenied: return "Your current organization role does not allow this privacy action. Refresh to check access."
        case .invalidDeletionConfirmation: return "Enter the exact organization name and your current password before requesting deletion."
        case .duplicateSubmission: return "A previous privacy request is unresolved. Refresh its history before submitting another request."
        case .unconfirmedOutcome: return "The service did not confirm this privacy request. Refresh and review its history before trying again."
        case let .uncertainOutcome(message): return message
        case let .requestFailed(status, message): return "Organization Privacy returned HTTP \(status): \(message)"
        }
    }
}
