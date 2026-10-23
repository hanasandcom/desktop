import Foundation

struct OrganizationPrivacySnapshot: Decodable, Equatable {
    let schemaVersion: String
    let organization: Organization
    let runs: [Record]
    let requests: [Record]
    let items: [Record]
    let itemPage: Page
    let protection: Protection
    let permissions: Permissions

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
        permissions = try c.decode(Permissions.self, forKey: .permissions)
    }

    func validate(organizationID: String, requestedOffset: Int) throws {
        guard schemaVersion == "organization.privacy_state.v1",
              organization.id == organizationID, !organization.name.isEmpty,
              organization.retentionDays >= 0,
              itemPage.offset == requestedOffset, itemPage.limit == 50,
              itemPage.nextOffset == nil || itemPage.nextOffset! > itemPage.offset,
              items.count <= itemPage.limit,
              [runs, requests, items].flatMap({ $0 }).allSatisfy({ $0.organizationID == organizationID && !$0.id.isEmpty }),
              Set(runs.map(\.id)).count == runs.count,
              Set(requests.map(\.id)).count == requests.count,
              [protection.protectedEvents, protection.totalRetentionItems, protection.accessRecoveryHolds,
               protection.immutableSystemEvents, protection.immutableWebhookAuditEvents, protection.immutableLogEvents].allSatisfy({ $0 >= 0 })
        else { throw OrganizationPrivacyError.invalidResponse }
    }
}

enum OrganizationPrivacyError: LocalizedError {
    case invalidBaseURL
    case signInRequired
    case invalidCredentials
    case impersonationUnsupported
    case organizationScopeChanged
    case invalidOffset
    case invalidResponse
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
        case let .requestFailed(status, message): return "Organization Privacy returned HTTP \(status): \(message)"
        }
    }
}
