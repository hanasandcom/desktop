import Foundation

struct SecurityScannerClient {
    let baseURL: URL
    let apiBaseURL: URL
    let organizationID: String
    let userID: String
    private let tokenState: SecurityScannerTokenState
    private var token: String { tokenState.read() }
    let settings: HanasandDesktopSettings
    var send: (URLRequest) async throws -> (Data, URLResponse)
    var onRefreshedToken: ((String) -> Void)?

    init(settings: HanasandDesktopSettings, baseURL: URL = URL(string: "https://scanner.hanasand.com/api")!,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         onRefreshedToken: ((String) -> Void)? = nil) throws {
        let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizationID = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !token.isEmpty else { throw SecurityScannerClientError.signInRequired }
        guard settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SecurityScannerClientError.impersonationUnsupported
        }
        guard userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SecurityScannerClientError.invalidCredentials
        }
        guard !organizationID.isEmpty, organizationID != "personal",
              settings.selectedOrganizationUserID == userID else { throw SecurityScannerClientError.selectOrganization }
        guard Self.validHTTPS(baseURL), Self.validHTTPS(settings.apiBaseURL.normalizedBaseURL) else {
            throw SecurityScannerClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.apiBaseURL = settings.apiBaseURL.normalizedBaseURL
        self.organizationID = organizationID
        self.userID = userID
        self.tokenState = SecurityScannerTokenState(token)
        self.settings = settings
        self.send = send ?? { request in try await URLSession.shared.data(for: request) }
        self.onRefreshedToken = onRefreshedToken
    }

    func dashboard() async throws -> SecurityScannerDashboard {
        let result: SecurityScannerDashboard = try await request("v1/uvm/dashboard")
        guard result.assets.allSatisfy({ !$0.id.isEmpty }), result.findings.allSatisfy({ !$0.id.isEmpty }) else {
            throw SecurityScannerClientError.invalidResponse
        }
        return result
    }

    func runHistory(cursor: String?) async throws -> SecurityScannerHistoryPage<SecurityScannerRun> {
        let receipt: RunHistoryReceipt = try await request(pagePath("v1/uvm/runs", key: "limit", value: "100", cursor: cursor))
        return SecurityScannerHistoryPage(items: receipt.runs, nextCursor: receipt.nextCursor)
    }

    func assessmentHistory(cursor: String?) async throws -> SecurityScannerHistoryPage<SecurityScannerAssessment> {
        let receipt: AssessmentHistoryReceipt = try await request(pagePath("v1/uvm/assessments", key: "limit", value: "50", cursor: cursor))
        return SecurityScannerHistoryPage(items: receipt.assessments, nextCursor: receipt.nextCursor)
    }

    func findingHistory(cursor: String?) async throws -> SecurityScannerHistoryPage<SecurityScannerFinding> {
        let receipt: FindingHistoryReceipt = try await request(pagePath("v1/uvm/findings", key: "limit", value: "100", cursor: cursor))
        return SecurityScannerHistoryPage(items: receipt.findings, nextCursor: receipt.nextCursor)
    }

    func createAsset(hostname: String) async throws -> SecurityScannerAsset {
        let name = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= 253, !name.contains("/"), !name.contains("@"),
              !name.contains(where: { $0.isWhitespace }) else { throw SecurityScannerClientError.invalidInput("Enter a valid hostname.") }
        try await requireEditorMembership()
        let receipt: AssetReceipt = try await request("v1/uvm/assets", method: "POST", body: ["hostname": name])
        guard receipt.asset.hostname == name else { throw SecurityScannerClientError.unconfirmedMutation }
        return receipt.asset
    }

    func verifyAsset(_ asset: SecurityScannerAsset) async throws -> SecurityScannerAsset {
        try requireCurrent(asset)
        try await requireEditorMembership()
        let receipt: AssetReceipt = try await request("v1/uvm/assets/\(segment(asset.id))/verify", method: "POST", body: [:])
        guard receipt.asset.id == asset.id else { throw SecurityScannerClientError.unconfirmedMutation }
        return receipt.asset
    }

    func runScan(asset: SecurityScannerAsset, engine: SecurityScannerEngineID, authorized: Bool,
                 nmapProfile: SecurityScannerNmapProfile = .top1000, tenableScanID: String? = nil) async throws -> SecurityScannerRun {
        try requireCurrent(asset)
        guard authorized else { throw SecurityScannerClientError.authorizationRequired }
        try await requireEditorMembership()
        let path: String
        var body: [String: Any] = ["requestId": UUID().uuidString, "authorized": true]
        switch engine {
        case .nmap: path = "v1/uvm/assets/\(segment(asset.id))/scans"; body["profile"] = nmapProfile.rawValue
        case .tenableVM:
            guard let tenableScanID, validID(tenableScanID) else { throw SecurityScannerClientError.invalidInput("Choose an enabled Tenable scan configuration.") }
            path = "v1/uvm/assets/\(segment(asset.id))/tenable-scans"; body["scanId"] = tenableScanID
        case .gvm: path = "v1/uvm/integrations/gvm/runs"; body["organizationId"] = organizationID; body["assetId"] = asset.id
        default:
            path = "v1/uvm/assets/\(segment(asset.id))/\(engine.rawValue)-scans"
            if let profile = engine.defaultProfile { body["profile"] = profile }
        }
        let receipt: RunReceipt = try await request(path, method: "POST", body: body)
        guard receipt.run.assetId == asset.id, receipt.run.engine == engine.rawValue else { throw SecurityScannerClientError.unconfirmedMutation }
        return receipt.run
    }

    func setSchedule(asset: SecurityScannerAsset, enabled: Bool, intervalMinutes: Int, authorized: Bool,
                     engines: [SecurityScannerEngineSelection]) async throws -> SecurityScannerAsset {
        try requireCurrent(asset)
        guard authorized else { throw SecurityScannerClientError.authorizationRequired }
        let engineIDs = engines.map(\.engine)
        guard (15...43_200).contains(intervalMinutes), !engines.isEmpty,
              engines.count <= SecurityScannerEngineID.allCases.count, Set(engineIDs).count == engineIDs.count,
              engines.allSatisfy({ SecurityScannerEngineID(rawValue: $0.engine) != nil }) else {
            throw SecurityScannerClientError.invalidInput("Choose a valid interval and at least one configured scanner.")
        }
        try await requireEditorMembership()
        let receipt: AssetReceipt = try await request("v1/uvm/assets/\(segment(asset.id))/schedule", method: "PUT", body: [
            "enabled": enabled, "intervalMinutes": intervalMinutes, "authorized": true,
            "engines": engines.map { selection in
                var value: [String: String] = ["engine": selection.engine]
                if let scanId = selection.scanId { value["scanId"] = scanId }
                if let profile = selection.profile { value["profile"] = profile }
                return value
            },
        ])
        guard receipt.asset.id == asset.id, receipt.asset.scheduleEnabled == enabled else { throw SecurityScannerClientError.unconfirmedMutation }
        return receipt.asset
    }

    func saveZapApiDefinition(asset: SecurityScannerAsset, path: String?) async throws -> SecurityScannerAsset {
        try requireCurrent(asset)
        let clean = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.map({ $0.isEmpty || ($0.count <= 2048 && $0.hasPrefix("/") && !$0.contains("..") && !$0.contains("\\") && !$0.contains("\0")) }) ?? true else {
            throw SecurityScannerClientError.invalidInput("Use an API definition path on the asset origin.")
        }
        try await requireEditorMembership()
        let receipt: AssetReceipt = try await request("v1/uvm/assets/\(segment(asset.id))/zap-api-definition", method: "PUT", body: ["path": (clean?.isEmpty == true) ? NSNull() : (clean as Any? ?? NSNull())])
        guard receipt.asset.id == asset.id, receipt.asset.zapApiDefinitionPath == (clean?.isEmpty == true ? nil : clean) else { throw SecurityScannerClientError.unconfirmedMutation }
        return receipt.asset
    }

    func configureTenable(region: String, accessKey: String, secretKey: String) async throws {
        guard ["us", "eu", "de", "au", "ca", "jp"].contains(region), !accessKey.isEmpty, !secretKey.isEmpty else {
            throw SecurityScannerClientError.invalidInput("Choose a region and enter both Tenable keys.")
        }
        try await requireEditorMembership()
        let receipt: TenableIntegrationReceipt = try await request("v1/uvm/integrations/tenable", method: "PUT", body: ["region": region, "accessKey": accessKey, "secretKey": secretKey])
        guard receipt.integration.configured, receipt.integration.error == nil else { throw SecurityScannerClientError.unconfirmedMutation }
    }

    func disconnectTenable() async throws {
        try await requireEditorMembership()
        let receipt: TenableIntegrationReceipt = try await request("v1/uvm/integrations/tenable", method: "DELETE", body: [:])
        guard !receipt.integration.configured else { throw SecurityScannerClientError.unconfirmedMutation }
    }

    func updateFinding(_ finding: SecurityScannerFinding, status: String, note: String) async throws {
        try requireFinding(finding)
        guard ["open", "in_progress", "pending_verification", "accepted_risk", "false_positive", "resolved"].contains(status), note.count <= 4000 else {
            throw SecurityScannerClientError.invalidInput("Choose a finding status and a note of 4,000 characters or fewer.")
        }
        try await requireEditorMembership()
        let _: EmptyReceipt = try await request("v1/uvm/findings/\(segment(finding.id))", method: "PUT", body: ["status": status, "note": note])
    }

    func cancelRun(_ run: SecurityScannerRun) async throws {
        try requireCurrent(run)
        guard ["queued", "launching", "running", "exporting", "cancelling"].contains(run.status) else { throw SecurityScannerClientError.invalidInput("This scan cannot be cancelled.") }
        try await requireEditorMembership()
        let receipt: RunReceipt = try await request("v1/uvm/runs/\(segment(run.id))/cancel", method: "POST", body: [:])
        guard receipt.run.id == run.id else { throw SecurityScannerClientError.unconfirmedMutation }
    }

    func startAssessment(assetIDs: [String], engines: [SecurityScannerEngineSelection], authorized: Bool) async throws -> SecurityScannerAssessment {
        let assets = Set(try await dashboard().assets.filter { $0.verificationStatus == "verified" }.map(\.id))
        let unique = Array(Set(assetIDs))
        guard authorized else { throw SecurityScannerClientError.authorizationRequired }
        guard !unique.isEmpty, unique.count <= 100, unique.allSatisfy(assets.contains), !engines.isEmpty,
              engines.count <= SecurityScannerEngineID.allCases.count,
              Set(engines.map(\.engine)).count == engines.count,
              engines.allSatisfy({ SecurityScannerEngineID(rawValue: $0.engine) != nil }) else {
            throw SecurityScannerClientError.invalidInput("Choose verified assets and available engines.")
        }
        try await requireEditorMembership()
        let receipt: AssessmentReceipt = try await request("v1/uvm/assessments", method: "POST", body: ["requestId": UUID().uuidString, "assetIds": unique, "engines": engines.map { item -> [String: String] in
            var value = ["engine": item.engine]
            if let scanID = item.scanId { value["scanId"] = scanID }
            if let profile = item.profile { value["profile"] = profile }
            return value
        }, "authorized": true])
        guard receipt.assessment.jobs.allSatisfy({ unique.contains($0.assetId) }) else { throw SecurityScannerClientError.unconfirmedMutation }
        return receipt.assessment
    }

    func cancelAssessment(_ assessment: SecurityScannerAssessment) async throws {
        guard assessment.status == "queued" || assessment.status == "running" else { throw SecurityScannerClientError.invalidInput("This assessment cannot be cancelled.") }
        try await requireEditorMembership()
        let receipt: AssessmentReceipt = try await request("v1/uvm/assessments/\(segment(assessment.id))/cancel", method: "POST", body: [:])
        guard receipt.assessment.id == assessment.id else { throw SecurityScannerClientError.unconfirmedMutation }
    }

    func assessmentReport(_ assessment: SecurityScannerAssessment) async throws -> SecurityScannerAssessmentReport {
        try requireCurrent(assessment)
        let receipt: AssessmentReportReceipt = try await request("v1/uvm/assessments/\(segment(assessment.id))/report")
        guard receipt.assessment.id == assessment.id else { throw SecurityScannerClientError.invalidResponse }
        return receipt.assessment
    }

    func run(id: String, engine: String) async throws -> SecurityScannerRun {
        guard validID(id), SecurityScannerEngineID(rawValue: engine) != nil else { throw SecurityScannerClientError.invalidInput("Choose a valid scanner run.") }
        let result: SecurityScannerRun = try await request("v1/uvm/runs/\(segment(id))?engine=\(segment(engine))")
        guard result.id == id, result.engine == engine else { throw SecurityScannerClientError.invalidResponse }
        return result
    }

    private func pagePath(_ path: String, key: String, value: String, cursor: String?) -> String {
        var parts = ["\(key)=\(value)"]
        if let cursor, !cursor.isEmpty { parts.append("cursor=\(segment(cursor))") }
        return "\(path)?\(parts.joined(separator: "&"))"
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host else { throw SecurityScannerClientError.invalidBaseURL }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }.joined(separator: "/")
        var query = pieces.count > 1 ? (URLComponents(string: "https://\(host)/?\(pieces[1])")?.queryItems ?? []) : []
        query.append(URLQueryItem(name: "organizationId", value: organizationID))
        components.queryItems = query
        guard let finalURL = components.url, finalURL.host == baseURL.host else { throw SecurityScannerClientError.invalidBaseURL }
        var request = URLRequest(url: finalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: method == "GET" ? 25 : 130)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .fragmentsAllowed])
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await send(request) }
        catch { throw SecurityScannerClientError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw SecurityScannerClientError.invalidResponse }
        acceptRefreshedToken(http)
        guard (200..<300).contains(http.statusCode) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[
                "message"] as? String ?? ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw SecurityScannerClientError.requestFailed(http.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SecurityScannerClientError.invalidResponse }
    }

    private func requireEditorMembership() async throws {
        let base = apiBaseURL.host?.lowercased() == "api.hanasand.com" ? URL(string: "https://identity.hanasand.com/api")! : apiBaseURL
        let membership: OrganizationMembershipReceipt = try await requestIdentity("organizations", base: base)
        guard let current = membership.organizations.first(where: { $0.id == organizationID && $0.status == "active" }),
              ["owner", "admin", "editor"].contains(current.role.lowercased()) else {
            throw SecurityScannerClientError.permissionDenied
        }
    }

    private func requestIdentity<T: Decodable>(_ path: String, base: URL) async throws -> T {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host else { throw SecurityScannerClientError.invalidBaseURL }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url, url.host == host else { throw SecurityScannerClientError.invalidBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw SecurityScannerClientError.invalidResponse }
        acceptRefreshedToken(http)
        guard (200..<300).contains(http.statusCode) else { throw SecurityScannerClientError.requestFailed(http.statusCode, "Organization permissions could not be verified.") }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SecurityScannerClientError.invalidResponse }
    }

    private func requireCurrent(_ item: SecurityScannerAsset) throws {
        guard validID(item.id) else { throw SecurityScannerClientError.invalidInput("Invalid asset.") }
    }
    private func requireCurrent(_ item: SecurityScannerRun) throws {
        guard validID(item.id), validID(item.assetId) else { throw SecurityScannerClientError.invalidInput("Invalid scan run.") }
    }
    private func requireCurrent(_ item: SecurityScannerAssessment) throws {
        guard validID(item.id) else { throw SecurityScannerClientError.invalidInput("Invalid assessment.") }
    }
    private func requireFinding(_ item: SecurityScannerFinding) throws {
        guard validID(item.id), item.assetId.map(validID) ?? true else { throw SecurityScannerClientError.invalidInput("Invalid finding.") }
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
    private func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && value.range(of: #"^[A-Za-z0-9._:@-]+$"#, options: .regularExpression) != nil
    }
    private static func validHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    private func acceptRefreshedToken(_ response: HTTPURLResponse) {
        guard let refreshed = response.value(forHTTPHeaderField: "x-access-token"), !refreshed.isEmpty else { return }
        tokenState.update(refreshed)
        onRefreshedToken?(refreshed)
    }
}

private final class SecurityScannerTokenState {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ value: String) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private struct AssetReceipt: Decodable { let asset: SecurityScannerAsset }
private struct RunReceipt: Decodable { let run: SecurityScannerRun }
private struct AssessmentReceipt: Decodable { let assessment: SecurityScannerAssessment }
private struct AssessmentReportReceipt: Decodable { let assessment: SecurityScannerAssessmentReport }
private struct TenableIntegrationReceipt: Decodable { let integration: SecurityScannerTenableIntegration }
private struct EmptyReceipt: Decodable {}
private struct OrganizationMembershipReceipt: Decodable { let organizations: [ThreatRuleOrganization] }
private struct RunHistoryReceipt: Decodable { let runs: [SecurityScannerRun]; let nextCursor: String? }
private struct AssessmentHistoryReceipt: Decodable { let assessments: [SecurityScannerAssessment]; let nextCursor: String? }
private struct FindingHistoryReceipt: Decodable { let findings: [SecurityScannerFinding]; let nextCursor: String? }

enum SecurityScannerClientError: LocalizedError {
    case invalidBaseURL, signInRequired, invalidCredentials, impersonationUnsupported, selectOrganization
    case permissionDenied, authorizationRequired, invalidResponse, unconfirmedMutation
    case invalidInput(String), requestFailed(Int, String?), transport(String)
    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "The Security Scanner requires a valid HTTPS address."
        case .signInRequired: "Sign in to use Security Scanner."
        case .invalidCredentials: "The account session cannot be sent safely. Sign in again."
        case .impersonationUnsupported: "Return to your own account to use Security Scanner."
        case .selectOrganization: "Choose the Hanasand organization workspace to use Security Scanner."
        case .permissionDenied: "An active organization editor role is required for this action."
        case .authorizationRequired: "Confirm that you are authorized to scan these assets."
        case .invalidResponse: "The scanner returned an unexpected response. Refresh and try again."
        case .unconfirmedMutation: "The result could not be confirmed. Refresh before trying again."
        case let .invalidInput(message): message
        case let .requestFailed(status, message): message ?? "Scanner request failed (HTTP \(status))."
        case let .transport(message): "Scanner service is unavailable: \(message)"
        }
    }
}
