import Foundation

struct ThreatFindingCaseDestination: Equatable {
    let caseID: String
    let alertID: String
    let organizationID: String?

    var query: [String: String] {
        var values = ["alertId": alertID]
        if let organizationID { values["organizationId"] = organizationID }
        return values
    }

    static func make(caseID: String, alertID: String, organizationID: String?) -> ThreatFindingCaseDestination? {
        guard isSafeIdentifier(caseID), isSafeIdentifier(alertID),
              organizationID.map(isSafeIdentifier) ?? true else { return nil }
        return ThreatFindingCaseDestination(caseID: caseID, alertID: alertID, organizationID: organizationID)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil
            && value != "." && value != ".."
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

struct ThreatFindingPage: Decodable {
    let organization: Organization?
    let visibilityDecision: VisibilityDecision
    let alerts: [ThreatFinding]
    let total: Int
    let nextCursor: String?

    struct Organization: Decodable { let id: String; let name: String? }
    struct VisibilityDecision: Decodable { let allowed: Bool }

    enum CodingKeys: String, CodingKey { case organization, visibilityDecision, alerts, total, nextCursor, pagination }
    private struct Pagination: Decodable { let nextCursor: String? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organization = try c.decodeIfPresent(Organization.self, forKey: .organization)
        visibilityDecision = try c.decode(VisibilityDecision.self, forKey: .visibilityDecision)
        guard visibilityDecision.allowed else {
            throw DecodingError.dataCorruptedError(forKey: .visibilityDecision, in: c, debugDescription: "Findings visibility is not allowed")
        }
        alerts = try c.decode([ThreatFinding].self, forKey: .alerts)
        total = try c.decode(Int.self, forKey: .total)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor) ?? c.decodeIfPresent(Pagination.self, forKey: .pagination)?.nextCursor
        guard total >= 0, alerts.count <= 50,
              nextCursor == nil || (nextCursor!.count <= 4096 && !nextCursor!.isEmpty && !nextCursor!.containsControlCharacters) else {
            throw DecodingError.dataCorruptedError(forKey: .alerts, in: c, debugDescription: "Findings page is invalid")
        }
        guard Set(alerts.map(\.id)).count == alerts.count else {
            throw DecodingError.dataCorruptedError(forKey: .alerts, in: c, debugDescription: "Findings page contains duplicate identifiers")
        }
    }

    func validate(tenantID: String, organizationID: String?, requestedCursor: String?) throws {
        guard organizationID == nil || organization?.id == organizationID,
              alerts.allSatisfy({ $0.tenantID == tenantID && $0.organizationID == organizationID }),
              requestedCursor == nil || nextCursor != requestedCursor else {
            throw ThreatFindingsError.invalidResponse
        }
    }
}

struct ThreatFinding: Decodable, Identifiable {
    let id: String
    let tenantID: String
    let organizationID: String?
    let title: String
    let actor: String
    let matchedTerm: String
    let severity: String
    let reviewState: String
    let deliveryState: String
    let summary: String
    let recommendedAction: String
    let observation: String
    let observedAt: String
    let caseID: String
    let evidence: [Evidence]

    struct Evidence: Decodable, Identifiable {
        let id: String
        let sourceName: String
        let captureMode: String
        let redactionState: String
        let excerpt: String
        let safeToShow: Bool
        let observedAt: String
        let publishedAt: String
        let collectedAt: String
        let captureID: String
        let contentHash: String

        private struct Provenance: Decodable { let captureId: String?; let publishedAt: String?; let collectedAt: String? }
        enum CodingKeys: String, CodingKey { case id, sourceName, captureMode, redactionState, safeToShow, excerpt, observedAt, firstSeenAt, provenance, contentHash }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let rawID = try c.decode(String.self, forKey: .id)
            guard rawID.isValidFindingID else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Evidence identifier is invalid") }
            id = rawID
            sourceName = Self.clean(try c.decodeIfPresent(String.self, forKey: .sourceName) ?? "Source not recorded")
            captureMode = Self.clean(try c.decodeIfPresent(String.self, forKey: .captureMode) ?? "")
            redactionState = Self.clean(try c.decodeIfPresent(String.self, forKey: .redactionState) ?? "")
            let declaredSafe = try c.decodeIfPresent(Bool.self, forKey: .safeToShow) ?? true
            safeToShow = redactionState != "raw_sensitive" && declaredSafe
            excerpt = safeToShow ? Self.safeExcerpt(try c.decodeIfPresent(String.self, forKey: .excerpt) ?? "") : ""
            let provenance = try c.decodeIfPresent(Provenance.self, forKey: .provenance)
            let observed = try c.decodeIfPresent(String.self, forKey: .observedAt)
            let firstSeen = try c.decodeIfPresent(String.self, forKey: .firstSeenAt)
            observedAt = Self.timestamp(observed ?? firstSeen ?? provenance?.publishedAt ?? "")
            publishedAt = Self.timestamp(provenance?.publishedAt ?? "")
            collectedAt = Self.timestamp(provenance?.collectedAt ?? "")
            captureID = Self.clean(provenance?.captureId ?? "", limit: 200)
            contentHash = Self.clean(try c.decodeIfPresent(String.self, forKey: .contentHash) ?? "", limit: 256)
        }

        private static func clean(_ value: String, limit: Int = 1000) -> String {
            value.replacingOccurrences(of: #"https://(?:canary\.)?discord(?:app)?\.com/api/webhooks/[^\s"'<>]+"#, with: "[webhook redacted]", options: .regularExpression)
                .replacingOccurrences(of: #"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{20,}\b"#, with: "[token redacted]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\b(token|secret|webhookUrl|authorization|apiKey)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,}\]]+)"#, with: "$1: [redacted]", options: .regularExpression)
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(limit).description
        }
        private static func safeExcerpt(_ raw: String) -> String {
            let text = clean(raw, limit: 8000)
            guard !text.isEmpty else { return "Evidence metadata is available." }
            let looksStructured = text.contains("{") || text.contains("[") || text.range(of: #"["'][A-Za-z0-9_ -]+["']\s*:"#, options: .regularExpression) != nil
            if !looksStructured {
                if text.localizedCaseInsensitiveContains("not extracted") { return "No actor entity identified in this capture." }
                if text.localizedCaseInsensitiveContains("parser") || text.localizedCaseInsensitiveContains("dynamic application data") { return "The page contained dynamic application data that could not be interpreted into structured fields." }
                return text
            }
            guard text.count <= 8000, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return "Evidence metadata is available." }
            let fields = ["actorName", "actor", "sourceName", "source", "victimName", "company", "domain", "category", "status", "artifactType", "observedAt"]
            func collect(_ value: Any, depth: Int = 0) -> [String] {
                guard depth <= 6 else { return [] }
                if let array = value as? [Any] { return array.prefix(3).flatMap { collect($0, depth: depth + 1) } }
                guard let dictionary = value as? [String: Any] else { return [] }
                return dictionary.flatMap { key, child -> [String] in
                    if fields.contains(key.lowercased()), let text = child as? String, !text.contains("{") && !text.contains("[") {
                        let safe = clean(text, limit: 160); return safe.isEmpty ? [] : [safe]
                    }
                    return collect(child, depth: depth + 1)
                }
            }
            return collect(object).joined(separator: " · ").nilIfEmpty ?? "Evidence metadata is available."
        }
        private static func timestamp(_ value: String) -> String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            guard let date else { return "" }
            return ISO8601DateFormatter().string(from: date)
        }
    }

    private struct MatchedTerm: Decodable { let value: String }
    private struct WorkflowContext: Decodable { let tenantId: String?; let organizationId: String?; let caseId: String? }
    private struct WebhookContext: Decodable { let tenantId: String?; let organizationId: String?; let caseId: String? }
    private struct EvidenceSummary: Decodable { let lastObservedAt: String? }
    private struct MatchTiming: Decodable { let kind: String? }
    enum CodingKeys: String, CodingKey {
        case id, tenantId, organizationId, orgId, company, actor, matchedTerm, severity, reviewState, deliveryState
        case observedMatchSummary, recommendedAction, sourceFamily, evidence, workflowContext, webhookContext, caseId
        case evidenceSummary, lastSeenAt, firstSeenAt, matchTiming
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decode(String.self, forKey: .id)
        let decodedTenantID = try c.decode(String.self, forKey: .tenantId)
        let organization = try c.decodeIfPresent(String.self, forKey: .organizationId) ?? c.decodeIfPresent(String.self, forKey: .orgId)
        let workflow = try c.decodeIfPresent(WorkflowContext.self, forKey: .workflowContext)
        let webhook = try c.decodeIfPresent(WebhookContext.self, forKey: .webhookContext)
        guard decodedID.isValidFindingID, decodedTenantID.isValidFindingID,
              [workflow?.tenantId, webhook?.tenantId].compactMap({ $0 }).allSatisfy({ $0 == decodedTenantID }),
              [workflow?.organizationId, webhook?.organizationId].compactMap({ $0 }).allSatisfy({ $0 == organization }) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Finding is outside the selected workspace")
        }
        id = decodedID
        tenantID = decodedTenantID
        organizationID = organization
        let term = try c.decode(MatchedTerm.self, forKey: .matchedTerm).value
        matchedTerm = Self.clean(term)
        title = Self.clean(try c.decodeIfPresent(String.self, forKey: .company) ?? "").nilIfEmpty ?? matchedTerm
        let rawActor = try c.decodeIfPresent(String.self, forKey: .actor) ?? ""
        actor = rawActor.count <= 200 && !rawActor.containsControlCharacters ? Self.clean(rawActor, limit: 200) : ""
        severity = Self.clean(try c.decodeIfPresent(String.self, forKey: .severity) ?? "")
        reviewState = Self.clean(try c.decodeIfPresent(String.self, forKey: .reviewState) ?? "")
        deliveryState = Self.clean(try c.decodeIfPresent(String.self, forKey: .deliveryState) ?? "")
        recommendedAction = Self.clean(try c.decodeIfPresent(String.self, forKey: .recommendedAction) ?? "", limit: 4000)
        let observed = Self.clean(try c.decodeIfPresent(String.self, forKey: .observedMatchSummary) ?? "")
        let structuredSummary = observed.contains("{") || observed.contains("[") || observed.range(of: #"["'][A-Za-z0-9_ -]+["']\s*:"#, options: .regularExpression) != nil
        let sourceFamily = Self.clean(try c.decodeIfPresent(String.self, forKey: .sourceFamily) ?? "threat").replacingOccurrences(of: "_", with: " ")
        let generatedFallback = "\(title) was mentioned in \(sourceFamily) intelligence. Investigate the retained evidence for its source and timing."
        let workflowText = observed.range(of: #"\b(reviewed|corroborated|parser|candidate|queue|worker|governance|evidence boundary)\b"#, options: .regularExpression) != nil
        summary = observed.isEmpty || structuredSummary || workflowText ? generatedFallback : observed
        let timing = try c.decodeIfPresent(MatchTiming.self, forKey: .matchTiming)?.kind
        observation = timing == "new_evidence" ? "New observation" : timing == "historical_backfill" ? "Historical match" : "Observation"
        let evidenceSummary = try c.decodeIfPresent(EvidenceSummary.self, forKey: .evidenceSummary)?.lastObservedAt
        let lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeenAt)
        let firstSeen = try c.decodeIfPresent(String.self, forKey: .firstSeenAt)
        observedAt = Self.timestamp(evidenceSummary ?? lastSeen ?? firstSeen ?? "")
        caseID = (try c.decodeIfPresent(String.self, forKey: .caseId) ?? workflow?.caseId ?? webhook?.caseId ?? "").nilIfValidFindingID ?? ""
        evidence = try c.decode([Evidence].self, forKey: .evidence)
        guard evidence.count <= 2000, Set(evidence.map(\.id)).count == evidence.count,
              organization != nil || ([workflow?.organizationId, webhook?.organizationId].compactMap({ $0 }).isEmpty) else {
            throw DecodingError.dataCorruptedError(forKey: .evidence, in: c, debugDescription: "Finding evidence is invalid")
        }
    }
    private static func clean(_ text: String, limit: Int = 1000) -> String {
        text.replacingOccurrences(of: #"https://(?:canary\.)?discord(?:app)?\.com/api/webhooks/[^\s"'<>]+"#, with: "[webhook redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{20,}\b"#, with: "[token redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(token|secret|webhookUrl|authorization|apiKey)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,}\]]+)"#, with: "$1: [redacted]", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(limit).description
    }
    private static func timestamp(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
}

extension ThreatFinding {
    var needsReview: Bool { !["resolved", "closed", "false_positive", "suppressed"].contains(reviewState) && deliveryState != "muted" }
    func contains(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || [title, actor, matchedTerm].contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

enum ThreatFindingsError: LocalizedError {
    case signIn, impersonating, invalidWorkspace, invalidResponse
    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to view Findings."
        case .impersonating: return "Return to your own account to view Findings."
        case .invalidWorkspace: return "Choose a valid workspace."
        case .invalidResponse: return "Findings returned an invalid page."
        }
    }
}

private extension String {
    var containsControlCharacters: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    var isValidFindingID: Bool { range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil && self != "." && self != ".." && !containsControlCharacters }
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var nilIfValidFindingID: String? { isValidFindingID ? self : nil }
}
