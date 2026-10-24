import Foundation

struct ThreatRulesClient {
    let settings: HanasandDesktopSettings
    var send: (URLRequest) async throws -> (Data, URLResponse) = { try await Self.session.data(for: $0) }
    static let tuningOrganizationID = "3e735e7b-4d7f-444d-9806-231fa26cfcec"
    private static let session = URLSession(configuration: .ephemeral, delegate: RejectThreatRulesRedirects(), delegateQueue: nil)

    func loadRules(category: String) async throws -> ThreatRulesPage {
        guard ["match", "analysis", "detection"].contains(category) else { throw ThreatRulesError.invalidInput("Choose a rule category.") }
        let organizationID = try requireOrganizationScope()
        guard let membership = try await organizations().first(where: { $0.id == organizationID && $0.status == "active" }) else {
            throw ThreatRulesError.organizationUnavailable
        }
        let query = [URLQueryItem(name: "organizationId", value: organizationID), URLQueryItem(name: "view", value: "list"), URLQueryItem(name: "category", value: category)]
        let envelope: RuleListEnvelope = try await request(path: "rules", query: query)
        guard envelope.organizationId == organizationID else { throw ThreatRulesError.organizationUnavailable }
        return ThreatRulesPage(organization: membership, canManageRetention: envelope.canManageRetention, rules: envelope.rules)
    }

    func loadRule(id: String, organizationID: String, offset: Int = 0) async throws -> RuleDetailEnvelope {
        try requireCurrentOrganization(organizationID)
        guard (0...1_000_000).contains(offset), id.range(of: #"^[A-Za-z0-9_.:@-]{1,200}$"#, options: .regularExpression) != nil else {
            throw ThreatRulesError.invalidInput("Choose a valid rule version and history page.")
        }
        var query = [URLQueryItem(name: "organizationId", value: organizationID)]
        if offset > 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        let envelope: RuleDetailEnvelope = try await request(path: "rules/\(segment(id))", query: query)
        guard envelope.organizationId == organizationID, ruleSlug(envelope.rule.id) == ruleSlug(id) else {
            throw ThreatRulesError.organizationUnavailable
        }
        if let requestedVersion = id.range(of: #"\.v(\d+)$"#, options: .regularExpression).map({ String(id[$0].dropFirst(2)) }),
           envelope.rule.version != requestedVersion {
            throw ThreatRulesError.organizationUnavailable
        }
        return envelope
    }

    func loadRuleHitCount(id: String, organizationID: String) async throws -> Int? {
        try requireCurrentOrganization(organizationID)
        let envelope: RuleHitCountEnvelope = try await request(
            path: "rules/\(segment(ruleSlug(id)))/hits",
            query: [URLQueryItem(name: "organizationId", value: organizationID)]
        )
        guard envelope.organizationId == organizationID else { throw ThreatRulesError.organizationUnavailable }
        return envelope.triggerCount
    }

    func loadRuleStorageEstimate(id: String, organizationID: String) async throws -> RuleStorageEstimateEnvelope.Estimate? {
        try requireCurrentOrganization(organizationID)
        let envelope: RuleStorageEstimateEnvelope = try await request(
            path: "rules/\(segment(ruleSlug(id)))/storage-estimate",
            query: [URLQueryItem(name: "organizationId", value: organizationID)]
        )
        guard envelope.organizationId == organizationID else { throw ThreatRulesError.organizationUnavailable }
        return envelope.estimate
    }

    func preview(definition: ThreatRuleJSON, organizationID: String, from: String, until: String, cursor: ThreatRulePreview.Cursor? = nil) async throws -> ThreatRulePreview {
        try requireCurrentOrganization(organizationID)
        guard validDate(from), validDate(until), Date.parse(from) < Date.parse(until) else { throw ThreatRulesError.invalidInput("Choose a valid preview range.") }
        let conditions = definition["conditions"]?.arrayValue ?? []
        guard (1...8).contains(conditions.count), conditions.allSatisfy(validCondition) else { throw ThreatRulesError.invalidInput("Add 1–8 valid conditions before checking matches.") }
        let body: [String: Any] = ["from": from, "until": until, "conditions": try jsonValue(conditions), "action": definition["action"]?.stringValue ?? "keep", "cursor": cursor.map { ["time": $0.time, "id": $0.id] as [String: Any] } ?? NSNull(), "sample": true, "limit": 1000, "storedLogsOnly": false]
        return try await request(path: "rules/preview", method: "POST", query: [URLQueryItem(name: "organizationId", value: organizationID)], body: body)
    }

    func saveRule(_ rule: ThreatRuleRecord?, category: String, organizationID: String, name: String, explanation: String, severity: String, enabled: Bool, definition: ThreatRuleJSON) async throws -> ThreatRuleRecord {
        try requireCurrentOrganization(organizationID)
        guard !isImpersonating else { throw ThreatRulesError.permissionDenied }
        guard let membership = try await organizations().first(where: { $0.id == organizationID && $0.status == "active" }),
              ["owner", "admin", "editor"].contains(membership.role.lowercased()) else { throw ThreatRulesError.permissionDenied }
        guard (2...120).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count),
              (10...500).contains(explanation.trimmingCharacters(in: .whitespacesAndNewlines).count),
              ["low", "medium", "high", "critical"].contains(severity) else { throw ThreatRulesError.invalidInput("Use a name of 2–120 characters, a description of 10–500 characters, and a valid severity.") }
        let stage = definition["stage"]?.stringValue ?? category
        let action = definition["action"]?.stringValue ?? "keep"
        guard ["match", "analysis", "detection", "analyze", "detect"].contains(stage), ["keep", "drop"].contains(action), stage == "analyze" || stage == "analysis" || action == "keep" else {
            throw ThreatRulesError.invalidInput("Only Analyze rules can drop events.")
        }
        if stage == "analyze" || stage == "analysis" {
            let current = try await loadRules(category: category)
            guard current.canManageRetention else { throw ThreatRulesError.permissionDenied }
        }
        let conditions = definition["conditions"]?.arrayValue ?? []
        guard (1...8).contains(conditions.count), conditions.allSatisfy(validCondition) else { throw ThreatRulesError.invalidInput("Add 1–8 valid conditions.") }
        if let rule, rule.source != "hanasand", stage != rule.stage {
            throw ThreatRulesError.invalidInput("An existing custom rule’s stage cannot be changed.")
        }
        if let scope = definition["storeScope"]?.stringValue, !["all", "custom_drop"].contains(scope) {
            throw ThreatRulesError.invalidInput("Choose a valid Store scope.")
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExplanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["name": cleanName, "explanation": cleanExplanation, "severity": action == "drop" ? "low" : severity, "enabled": enabled]
        if let rule {
            let latest = try await loadRule(id: ruleSlug(rule.id), organizationID: organizationID)
            guard latest.canEdit, !latest.isHistorical, latest.rule.version == rule.version else { throw ThreatRulesError.permissionDenied }
            body["version"] = rule.version
            if rule.source == "hanasand" { body["definition"] = try jsonValue(definition) }
            else {
                body["conditions"] = try jsonValue(conditions)
                body["action"] = action
                if let scope = definition["storeScope"]?.stringValue { body["storeScope"] = scope }
            }
            let envelope: RuleReceiptEnvelope = try await request(path: "rules/\(segment(ruleSlug(rule.id)))", method: "PUT", query: [URLQueryItem(name: "organizationId", value: organizationID)], body: body, mutation: true)
            guard envelope.rule.id.replacingOccurrences(of: #"\.v\d+$"#, with: "", options: .regularExpression) == ruleSlug(rule.id) else { throw ThreatRulesError.unconfirmedMutation }
            return envelope.rule
        } else {
            body["stage"] = stage == "analysis" ? "analyze" : stage == "detection" ? "detect" : stage
            body["action"] = action
            body["match"] = "all"
            body["conditions"] = try jsonValue(conditions)
            let envelope: RuleReceiptEnvelope = try await request(path: "rules", method: "POST", query: [URLQueryItem(name: "organizationId", value: organizationID)], body: body, mutation: true)
            guard envelope.rule.enabled, envelope.rule.source == "owned" else { throw ThreatRulesError.unconfirmedMutation }
            return envelope.rule
        }
    }

    func tuningAccess() async throws -> TuningAccess {
        try requireAuthenticated()
        let response: TuningAccessEnvelope = try await request(path: "management/organizations", query: [URLQueryItem(name: "internalPages", value: "1")])
        guard response.allowed else { throw ThreatRulesError.permissionDenied }
        return TuningAccess(canWrite: response.canEdit && !isImpersonating)
    }

    func importRulePack(organizationID: String, packName: String, packVersion: String, sourceReference: String, json: String) async throws -> ThreatRuleImportReceipt {
        try await requireRuleImportAccess(organizationID)
        let metadata = try validatedPackMetadata(name: packName, version: packVersion, sourceReference: sourceReference)
        guard let data = json.data(using: .utf8), let document = try? JSONDecoder().decode(ThreatRuleJSON.self, from: data),
              let rules = document["rules"]?.arrayValue, (1...100).contains(rules.count), rules.allSatisfy(validImportedRule) else {
            throw ThreatRulesError.invalidInput("Enter a JSON pack with 1–100 valid rules.")
        }
        let body: [String: Any] = [
            "packName": metadata.name,
            "packVersion": metadata.version,
            "sourceReference": metadata.sourceReference,
            "rules": try jsonValue(rules),
        ]
        let receipt: ThreatRuleImportReceipt
        do {
            receipt = try await request(
                path: "rules/packs", method: "POST",
                query: [URLQueryItem(name: "organizationId", value: organizationID)], body: body, mutation: true
            )
        } catch ThreatRulesError.invalidResponse {
            throw ThreatRulesError.unconfirmedMutation
        }
        guard receipt.imported == rules.count, receipt.pack.name == metadata.name,
              receipt.pack.version == metadata.version, receipt.pack.sourceReference == metadata.sourceReference else {
            throw ThreatRulesError.unconfirmedMutation
        }
        return receipt
    }

    func importSigmaPack(organizationID: String, packName: String, packVersion: String, sourceReference: String, yaml: String) async throws -> ThreatRuleImportReceipt {
        try await requireRuleImportAccess(organizationID)
        let metadata = try validatedPackMetadata(name: packName, version: packVersion, sourceReference: sourceReference)
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, yaml.utf16.count <= 200_000 else {
            throw ThreatRulesError.invalidInput("Provide one Sigma YAML document up to 200,000 characters.")
        }
        let body: [String: Any] = [
            "packName": metadata.name,
            "packVersion": metadata.version,
            "sourceReference": metadata.sourceReference,
            "yaml": yaml,
        ]
        let receipt: ThreatRuleImportReceipt
        do {
            receipt = try await request(
                path: "rules/sigma", method: "POST",
                query: [URLQueryItem(name: "organizationId", value: organizationID)], body: body, mutation: true
            )
        } catch ThreatRulesError.invalidResponse {
            throw ThreatRulesError.unconfirmedMutation
        }
        guard receipt.imported > 0, receipt.pack.name == metadata.name,
              receipt.pack.version == metadata.version, receipt.pack.sourceReference == metadata.sourceReference else {
            throw ThreatRulesError.unconfirmedMutation
        }
        return receipt
    }

    private func requireRuleImportAccess(_ organizationID: String) async throws {
        try requireCurrentOrganization(organizationID)
        guard !isImpersonating,
              let member = try await organizations().first(where: { $0.id == organizationID && $0.status == "active" }),
              ["owner", "admin"].contains(member.role.lowercased()) else {
            throw ThreatRulesError.permissionDenied
        }
        guard try requireOrganizationScope() == organizationID else { throw ThreatRulesError.organizationScopeChanged }
    }

    private func validatedPackMetadata(name: String, version: String, sourceReference: String) throws -> (name: String, version: String, sourceReference: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReference = sourceReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(cleanName.utf16.count), (1...40).contains(cleanVersion.utf16.count),
              cleanReference.utf16.count <= 300,
              let reference = URLComponents(string: cleanReference), reference.scheme?.lowercased() == "https", reference.host != nil,
              reference.user == nil, reference.password == nil else {
            throw ThreatRulesError.invalidInput("Use a pack name of 2–100 characters, a version of 1–40 characters, and an HTTPS source reference up to 300 characters.")
        }
        return (cleanName, cleanVersion, cleanReference)
    }

    private func validImportedRule(_ value: ThreatRuleJSON) -> Bool {
        guard let object = value.objectValue,
              let rawID = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawID.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil,
              let name = (object["name"]?.stringValue ?? object["title"]?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (2...120).contains(name.utf16.count),
              let explanation = (object["explanation"]?.stringValue ?? object["description"]?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (10...500).contains(explanation.utf16.count),
              let conditions = object["conditions"]?.arrayValue, (1...8).contains(conditions.count), conditions.allSatisfy(validCondition) else {
            return false
        }
        return true
    }

    func loadTuningSnapshot(access: TuningAccess) async throws -> ThreatRuleTuningSnapshot {
        try requireTuningAccess(access, write: false)
        let snapshot: ThreatRuleTuningSnapshot = try await request(path: "logs/tuning")
        guard snapshot.organizationId == Self.tuningOrganizationID, snapshot.logs.count <= 100 else { throw ThreatRulesError.invalidResponse }
        return snapshot
    }

    func refreshTuningSnapshot(access: TuningAccess) async throws {
        try requireTuningAccess(access, write: true)
        let receipt: TuningRefreshReceipt = try await request(path: "logs/tuning/refresh", method: "POST", body: [:], mutation: true)
        guard receipt.refreshing else { throw ThreatRulesError.unconfirmedMutation }
    }

    func loadTuningRules(access: TuningAccess) async throws -> [ThreatRuleSummary] {
        try requireTuningAccess(access, write: false)
        let envelope: TuningRuleListEnvelope = try await request(path: "rules", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID), URLQueryItem(name: "view", value: "list")])
        guard envelope.organizationId == Self.tuningOrganizationID else { throw ThreatRulesError.organizationUnavailable }
        return envelope.rules.filter { $0.source == "owned" }
    }

    func loadTuningRule(id: String, access: TuningAccess) async throws -> ThreatRuleRecord {
        try requireTuningAccess(access, write: false)
        let envelope: RuleDetailEnvelope = try await request(path: "rules/\(segment(ruleSlug(id)))", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID)])
        guard envelope.organizationId == Self.tuningOrganizationID, !envelope.isHistorical,
              ruleSlug(envelope.rule.id) == ruleSlug(id) else { throw ThreatRulesError.organizationUnavailable }
        return envelope.rule
    }

    func previewStored(conditions: [ThreatRuleCondition], action: String, access: TuningAccess, from: String?, until: String) async throws -> StoredRulePreview {
        try requireTuningAccess(access, write: false)
        guard !conditions.isEmpty, conditions.count <= 8, conditions.allSatisfy(validCondition), ["keep", "drop"].contains(action), validDate(until), from.map(validDate) ?? true else { throw ThreatRulesError.invalidInput("Choose valid rule conditions and a time range.") }
        let body: [String: Any] = ["from": from as Any? ?? NSNull(), "until": until, "conditions": try jsonValue(conditions.map(jsonCondition)), "action": action, "cursor": NSNull(), "sample": true, "limit": 2000, "storedLogsOnly": true]
        let preview: StoredRulePreview = try await request(path: "rules/preview", method: "POST", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID)], body: body)
        return preview
    }

    func createTuningRule(access: TuningAccess, name: String, explanation: String, conditions: [ThreatRuleCondition]) async throws -> ThreatRuleRecord {
        try requireTuningAccess(access, write: true)
        guard (2...120).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count), (10...500).contains(explanation.trimmingCharacters(in: .whitespacesAndNewlines).count),
              (1...8).contains(conditions.count), conditions.allSatisfy(validCondition) else { throw ThreatRulesError.invalidInput("Check the rule name, description, and 1–8 valid conditions.") }
        let body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "explanation": explanation.trimmingCharacters(in: .whitespacesAndNewlines), "severity": "low", "stage": "analyze", "action": "drop", "match": "all", "conditions": try jsonValue(conditions.map(jsonCondition))]
        let envelope: RuleReceiptEnvelope = try await request(path: "rules", method: "POST", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID)], body: body, mutation: true)
        guard envelope.rule.source == "owned", envelope.rule.enabled, envelope.rule.stage == "analyze", envelope.rule.action == "drop" else { throw ThreatRulesError.unconfirmedMutation }
        return envelope.rule
    }

    func loadReprocessing(rule: ThreatRuleRecord, access: TuningAccess) async throws -> ThreatRuleReprocessState {
        try requireTuningAccess(access, write: false)
        try requireReprocessable(rule)
        let state: ThreatRuleReprocessState = try await request(path: "rules/\(segment(ruleSlug(rule.id)))/reprocess", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID)])
        guard state.jobs.count <= 10, state.jobs.allSatisfy({ ruleSlug($0.ruleID) == ruleSlug(rule.id) }) else { throw ThreatRulesError.invalidResponse }
        return state
    }

    func startReprocessing(rule: ThreatRuleRecord, preview: StoredRulePreview, reviewedVersion: String, access: TuningAccess) async throws -> ThreatRuleReprocessJob {
        try requireTuningAccess(access, write: true)
        try requireReprocessable(rule)
        guard reviewedVersion == rule.version, preview.count >= 0 else { throw ThreatRulesError.invalidInput("Preview the current saved rule before starting reprocessing.") }
        let current = try await loadTuningRule(id: rule.id, access: access)
        guard current.version == rule.version, current.enabled, current.source == "owned", current.stage == "analyze", current.action == "drop" else { throw ThreatRulesError.permissionDenied }
        let body: [String: Any] = ["confirm": true, "version": rule.version, "from": NSNull()]
        let envelope: ReprocessJobEnvelope = try await request(path: "rules/\(segment(ruleSlug(rule.id)))/reprocess", method: "POST", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID)], body: body, mutation: true)
        guard envelope.job.ruleVersion == rule.version, ["queued", "running"].contains(envelope.job.status) else { throw ThreatRulesError.unconfirmedMutation }
        return envelope.job
    }

    func cancelReprocessing(rule: ThreatRuleRecord, job: ThreatRuleReprocessJob, access: TuningAccess) async throws -> ThreatRuleReprocessJob {
        try requireTuningAccess(access, write: true)
        try requireReprocessable(rule)
        guard ["queued", "running"].contains(job.status), ruleSlug(job.ruleID) == ruleSlug(rule.id) else { throw ThreatRulesError.permissionDenied }
        let body: [String: Any] = ["action": "cancel", "jobId": job.id]
        let envelope: ReprocessJobEnvelope = try await request(path: "rules/\(segment(ruleSlug(rule.id)))/reprocess", method: "POST", query: [URLQueryItem(name: "organizationId", value: Self.tuningOrganizationID)], body: body, mutation: true)
        guard envelope.job.id == job.id, envelope.job.status == "cancelled" else { throw ThreatRulesError.unconfirmedMutation }
        return envelope.job
    }

    private var isImpersonating: Bool { !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func organizations() async throws -> [ThreatRuleOrganization] {
        let base = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = base == "https://api.hanasand.com/api" ? "https://identity.hanasand.com/api" : base
        let envelope: OrganizationListEnvelope = try await request(path: "organizations", base: url)
        return envelope.organizations
    }

    private func requireOrganizationScope() throws -> String {
        try requireAuthenticated()
        let organizationID = settings.selectedOrganizationID
        guard !organizationID.isEmpty, organizationID != "personal",
              settings.selectedOrganizationUserID == settings.userID else { throw ThreatRulesError.selectOrganization }
        return organizationID
    }

    private func requireCurrentOrganization(_ organizationID: String) throws {
        guard try requireOrganizationScope() == organizationID else { throw ThreatRulesError.organizationScopeChanged }
    }

    private func requireAuthenticated() throws {
        guard !settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ThreatRulesError.signInRequired }
    }

    private func requireTuningAccess(_ access: TuningAccess, write: Bool) throws {
        try requireAuthenticated()
        guard access.verified, !isImpersonating || !write, !write || access.canWrite else { throw ThreatRulesError.permissionDenied }
    }

    private func request<T: Decodable>(path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil, base: String? = nil, mutation: Bool = false) async throws -> T {
        let rawBase = (base ?? settings.apiBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: rawBase), components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { throw ThreatRulesError.invalidBaseURL }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, path].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ThreatRulesError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = method == "GET" ? 25 : 130
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        if !settings.impersonationToken.isEmpty { request.setValue(settings.impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed, .sortedKeys]) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await send(request) }
        catch { if mutation { throw ThreatRulesError.unconfirmedMutation }; throw error }
        guard let response = response as? HTTPURLResponse else { throw ThreatRulesError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if mutation && response.statusCode >= 500 { throw ThreatRulesError.unconfirmedMutation }
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message)
            throw ThreatRulesError.requestFailed(response.statusCode, message ?? "Threat rules request failed")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ThreatRulesError.invalidResponse }
    }

    private func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? "" }
    private func ruleSlug(_ id: String) -> String { id.replacingOccurrences(of: #"\.v\d+$"#, with: "", options: .regularExpression) }
    private func validDate(_ value: String) -> Bool { ISO8601DateFormatter().date(from: value) != nil }
    private func requireReprocessable(_ rule: ThreatRuleRecord) throws {
        guard rule.id.range(of: #"^[A-Za-z0-9_.:@-]{1,200}$"#, options: .regularExpression) != nil,
              !rule.version.isEmpty, rule.source == "owned", rule.enabled, rule.stage == "analyze", rule.action == "drop" else {
            throw ThreatRulesError.invalidInput("Save and enable an Analyze drop rule before reprocessing.")
        }
    }
    private func validCondition(_ value: ThreatRuleJSON) -> Bool {
        guard let object = value.objectValue,
              let path = object["path"]?.stringValue,
              let operation = object["operator"]?.stringValue,
              let match = object["value"]?.stringValue else { return false }
        let valid = path.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil
            && ["equals", "contains", "regex"].contains(operation) && !match.isEmpty && match.count <= 200
        return valid && (operation != "regex" || (try? NSRegularExpression(pattern: match)) != nil)
    }
    private func validCondition(_ value: ThreatRuleCondition) -> Bool {
        let valid = value.path.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil
            && ["equals", "contains", "regex"].contains(value.operation) && !value.value.isEmpty && value.value.count <= 200
        return valid && (value.operation != "regex" || (try? NSRegularExpression(pattern: value.value)) != nil)
    }
    private func jsonCondition(_ value: ThreatRuleCondition) -> ThreatRuleJSON {
        var object: [String: ThreatRuleJSON] = ["path": .string(value.path), "operator": .string(value.operation), "value": .string(value.value)]
        if let sensitive = value.caseSensitive { object["caseSensitive"] = .bool(sensitive) }
        return .object(object)
    }
    private func jsonValue(_ value: [ThreatRuleJSON]) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    private func jsonValue(_ value: ThreatRuleJSON) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

private final class RejectThreatRulesRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct TuningAccess: Equatable { let verified = true; let canWrite: Bool }
struct RuleListEnvelope: Decodable { let organizationId: String; let rules: [ThreatRuleRecord]; let canManageRetention: Bool }
private struct TuningRuleListEnvelope: Decodable { let organizationId: String; let rules: [ThreatRuleSummary] }
struct RuleDetailEnvelope: Decodable { let organizationId: String; let canEdit: Bool; let isHistorical: Bool; let rule: ThreatRuleRecord; let triggerCount: Int?; let audit: [RuleAuditRecord]; let nextOffset: Int? }
struct RuleAuditRecord: Decodable, Identifiable {
    let id: String
    let event_type: String
    let actor_id: String?
    let created_at: String
    let context: [String: ThreatRuleJSON]

    var before: [String: ThreatRuleJSON] { context["before"]?.objectValue ?? [:] }
    var after: [String: ThreatRuleJSON] { context["after"]?.objectValue ?? [:] }
    var action: String? { context["action"]?.stringValue }

    private enum CodingKeys: String, CodingKey { case id, event_type, actor_id, created_at, context }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        event_type = try container.decode(String.self, forKey: .event_type)
        actor_id = try container.decodeIfPresent(String.self, forKey: .actor_id)
        created_at = try container.decode(String.self, forKey: .created_at)
        context = try container.decodeIfPresent([String: ThreatRuleJSON].self, forKey: .context) ?? [:]
    }
}
struct RuleHitCountEnvelope: Decodable { let organizationId: String; let triggerCount: Int? }
struct RuleStorageEstimateEnvelope: Decodable {
    struct Estimate: Decodable, Equatable { let count: Int; let bytes: Int; let checkedDate: String; let generatedAt: String }
    let organizationId: String
    let estimate: Estimate?
}
struct RuleReceiptEnvelope: Decodable { let rule: ThreatRuleRecord }
private struct OrganizationListEnvelope: Decodable { let organizations: [ThreatRuleOrganization] }
private struct TuningAccessEnvelope: Decodable { let allowed: Bool; let canEdit: Bool }
private struct TuningRefreshReceipt: Decodable { let refreshing: Bool }
private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail

    private enum CodingKeys: String, CodingKey { case error }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try? container.decode(String.self, forKey: .error) {
            error = Detail(message: message)
        } else if let detail = try? container.decode(Detail.self, forKey: .error) {
            error = detail
        } else {
            error = Detail(message: "Threat rules request failed")
        }
    }
}
struct StoredRulePreview: Decodable { let count: Int; let scanned: Int; let bytes: Int; let events: [ThreatRulePreview.Event]; let cursor: ThreatRulePreview.Cursor? }
private struct ReprocessJobEnvelope: Decodable { let job: ThreatRuleReprocessJob }

enum ThreatRulesError: LocalizedError {
    case invalidBaseURL, signInRequired, selectOrganization, organizationUnavailable, organizationScopeChanged, permissionDenied
    case invalidInput(String), invalidResponse, unconfirmedMutation, requestFailed(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Threat rules require a secure API URL."
        case .signInRequired: return "Sign in to use threat rules."
        case .selectOrganization: return "Select an active organization in the Organizations workspace."
        case .organizationUnavailable: return "The selected organization could not be verified. Refresh rules."
        case .organizationScopeChanged: return "The selected organization changed. Reload before continuing."
        case .permissionDenied: return "Your current account or role cannot make this change."
        case let .invalidInput(message): return message
        case .invalidResponse: return "The threat rules service returned an invalid response."
        case .unconfirmedMutation: return "The change could not be confirmed. Refresh before trying again."
        case let .requestFailed(status, message): return "Threat rules returned HTTP \(status): \(message)"
        }
    }
}

private extension Date {
    static func parse(_ value: String) -> Date { ISO8601DateFormatter().date(from: value) ?? .distantPast }
}
