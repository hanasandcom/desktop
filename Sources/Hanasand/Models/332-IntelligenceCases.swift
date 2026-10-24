import Foundation

enum IntelligenceCaseJSON: Decodable, Equatable {
    case object([String: IntelligenceCaseJSON])
    case array([IntelligenceCaseJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: IntelligenceCaseJSON].self) { self = .object(value) }
        else if let value = try? container.decode([IntelligenceCaseJSON].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported case value") }
    }

    var stringValue: String { if case .string(let value) = self { value } else { "" } }
    var objectValue: [String: IntelligenceCaseJSON] { if case .object(let value) = self { value } else { [:] } }
    var arrayValue: [IntelligenceCaseJSON] { if case .array(let value) = self { value } else { [] } }
    subscript(_ key: String) -> IntelligenceCaseJSON? { objectValue[key] }
}

struct IntelligenceCaseAction: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let method: String
    let requiresRationale: Bool
    let enabled: Bool
    let disabledReason: String

    enum CodingKeys: String, CodingKey { case id, label, method, requiresRationale, enabled, disabledReason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id.replacingOccurrences(of: "_", with: " ").capitalized
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "PATCH"
        requiresRationale = try c.decodeIfPresent(Bool.self, forKey: .requiresRationale) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
    }
}

struct IntelligenceCaseRow: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let status: String
    let severity: String
    let assignedOwner: String
    let organizationID: String
    let tenantID: String
    let updatedAt: String
    let createdAt: String
    let source: String
    let raw: [String: IntelligenceCaseJSON]

    enum CodingKeys: String, CodingKey { case id, caseId, title, summary, status, severity, priority, assignedOwner, organizationId, tenantId, updatedAt, createdAt, source }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .caseId) ?? c.decode(String.self, forKey: .id)
        guard !id.isEmpty, id.count <= 200 else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid case identity") }
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled case"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? c.decodeIfPresent(String.self, forKey: .priority) ?? ""
        assignedOwner = try c.decodeIfPresent(String.self, forKey: .assignedOwner) ?? ""
        organizationID = try c.decodeIfPresent(String.self, forKey: .organizationId) ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantId) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "intelligence"
        raw = (try? decoder.singleValueContainer().decode([String: IntelligenceCaseJSON].self)) ?? [:]
    }
}

struct IntelligenceCasePage: Decodable, Equatable {
    let items: [IntelligenceCaseRow]
    let nextCursor: String?
    let total: Int?

    enum CodingKeys: String, CodingKey { case items, cases, nextCursor, total }
    init(items: [IntelligenceCaseRow], nextCursor: String?, total: Int?) {
        self.items = items
        self.nextCursor = nextCursor
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([IntelligenceCaseRow].self, forKey: .items) ?? c.decodeIfPresent([IntelligenceCaseRow].self, forKey: .cases) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct IntelligenceCaseDetailEnvelope: Decodable, Equatable {
    let caseRecord: IntelligenceCaseRow
    let timeline: [IntelligenceCaseJSON]
    let evidence: [IntelligenceCaseJSON]
    let actions: [IntelligenceCaseAction]
    let readOnly: Bool
    let alertContext: [String: IntelligenceCaseJSON]

    enum CodingKeys: String, CodingKey { case caseRecord = "case", timeline, evidence, nextAllowedActions, workflowActionPolicy, access, alertContext }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caseRecord = try c.decode(IntelligenceCaseRow.self, forKey: .caseRecord)
        timeline = try c.decodeIfPresent([IntelligenceCaseJSON].self, forKey: .timeline) ?? []
        evidence = try c.decodeIfPresent([IntelligenceCaseJSON].self, forKey: .evidence) ?? []
        let policy = try c.decodeIfPresent(Policy.self, forKey: .workflowActionPolicy)
        actions = policy?.actions.isEmpty == false ? policy!.actions : (try c.decodeIfPresent([IntelligenceCaseAction].self, forKey: .nextAllowedActions) ?? [])
        let access = try c.decodeIfPresent(Access.self, forKey: .access)
        readOnly = access?.readOnly == true || policy?.summary?.readOnly == true
        alertContext = try c.decodeIfPresent([String: IntelligenceCaseJSON].self, forKey: .alertContext) ?? [:]
    }

    private struct Access: Decodable { let readOnly: Bool? }
    private struct Policy: Decodable {
        let actions: [IntelligenceCaseAction]
        let summary: Summary?
        struct Summary: Decodable { let readOnly: Bool? }
    }
}

enum IntelligenceCasesError: LocalizedError, Equatable {
    case signInRequired, impersonationUnsupported, invalidURL, invalidResponse, responseTooLarge
    case requestFailed(Int), scopeChanged, mutationOutcomeUnknown

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view intelligence cases."
        case .impersonationUnsupported: "Return to your own account to access intelligence cases."
        case .invalidURL: "Cases require a secure Hanasand website address."
        case .invalidResponse: "The intelligence case response could not be verified. Refresh and review."
        case .responseTooLarge: "The case response exceeded the 8 MiB limit."
        case .requestFailed(401): "Sign in again to view intelligence cases."
        case .requestFailed(403): "Current organization access could not be verified."
        case .requestFailed(404): "This intelligence case is no longer available."
        case .requestFailed(let status): "Intelligence cases request failed (HTTP \(status))."
        case .scopeChanged: "The selected organization changed. Refresh before continuing."
        case .mutationOutcomeUnknown: "The change outcome is unknown. Refresh the case and review its timeline before trying again."
        }
    }
}
