import Foundation

struct DwmCaseWorkflowClient {
    private let settings: HanasandDesktopSettings
    private let organizationID: String?
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private static let responseLimit = 8 * 1024 * 1024

    init(settings: HanasandDesktopSettings, organizationIDOverride: String? = nil,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else { throw DwmCaseWorkflowError.signInRequired }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw DwmCaseWorkflowError.impersonationUnsupported }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else { throw DwmCaseWorkflowError.signInRequired }
        let selected = organizationIDOverride ?? settings.selectedOrganizationID
        let clean = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = clean.isEmpty || clean == "personal" ? nil : clean
        if let scope {
            guard scope.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
                  settings.selectedOrganizationUserID == settings.userID else { throw DwmCaseWorkflowError.organizationRequired }
        }
        for raw in [settings.websiteBaseURL, settings.apiBaseURL] {
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw DwmCaseWorkflowError.invalidEndpoint }
        }
        self.settings = settings
        organizationID = scope
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: DwmCaseWorkflowRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func load(caseID: String, alertID: String?) async throws -> DwmCaseWorkflowSnapshot {
        guard IntelligenceCasesClient.validCaseID(caseID) else { throw DwmCaseWorkflowError.invalidInput }
        let caseRoot = try await getJSON(service: .ti, path: "/v1/cases/\(encoded(caseID))", query: scopeQuery(alertID: alertID))
        guard caseRoot["case"]?["id"]?.stringValue == caseID,
              Self.scopeMatches(caseRoot["case"]?.objectValue ?? [:], organizationID: organizationID, userID: settings.userID) else { throw DwmCaseWorkflowError.scopeChanged }
        let notificationRows = caseRoot["case"]?["customerNotifications"]?.arrayValue.map(\.objectValue) ?? []
        guard notificationRows.count <= 100 else { throw DwmCaseWorkflowError.malformedResponse }
        var exportQuery = scopeQuery(alertID: alertID)
        exportQuery.append(URLQueryItem(name: "shape", value: "full"))
        let export = try await getJSON(service: .ti, path: "/v1/cases/\(encoded(caseID))/export", query: exportQuery)
        guard let checksum = export["exportChecksum"]?.stringValue, checksum.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            throw DwmCaseWorkflowError.malformedResponse
        }

        guard let organizationID, let alertID, !alertID.isEmpty else {
            return DwmCaseWorkflowSnapshot(export: export, destinations: [], deliveries: [], receiverReceipts: [], customerNotificationReceipts: notificationRows, caseID: caseID, organizationID: organizationID, alertID: alertID, canManageDestinations: false, liveDeliveryEnabled: false)
        }
        let integration = try await IntegrationClient(apiBaseURL: URL(string: settings.apiBaseURL)!, userID: settings.userID,
            token: settings.authToken, organizationID: organizationID, impersonationToken: settings.impersonationToken,
            impersonatingUserID: settings.impersonatingUserID, send: send).load()
        async let deliveryData = getJSON(service: .api, path: "/dwm/webhook-deliveries", query: [
            URLQueryItem(name: "orgId", value: organizationID), URLQueryItem(name: "alertId", value: alertID), URLQueryItem(name: "reportCaseId", value: caseID),
        ])
        async let receiverData = getJSON(service: .api, path: "/findings/webhook-receiver", query: [
            URLQueryItem(name: "orgId", value: organizationID), URLQueryItem(name: "reportCaseId", value: caseID),
        ])
        let (deliveries, receiver) = try await (deliveryData, receiverData)
        let destinationRows = integration.destinations
        let deliveryRows = rows(deliveries, keys: ["deliveryLedger"])
        let receiptRows = rows(receiver, keys: ["receipts", "items"])
        let liveEnabled = deliveries["deliveryOperations"]?["liveDeliveryEnabled"] == .bool(true)
        guard destinationRows.count <= 100, deliveryRows.count <= 100, receiptRows.count <= 100,
              deliveryRows.allSatisfy({ $0["orgId"]?.stringValue == organizationID && $0["alertId"]?.stringValue == alertID && $0["reportCaseId"]?.stringValue == caseID && $0["thirdPartyReport"] == .bool(true) }),
              receiptRows.allSatisfy({ $0["orgId"] == nil || $0["orgId"]?.stringValue == organizationID }) else {
            throw DwmCaseWorkflowError.scopeChanged
        }
        return DwmCaseWorkflowSnapshot(export: export, destinations: destinationRows, deliveries: deliveryRows, receiverReceipts: receiptRows, customerNotificationReceipts: notificationRows,
                                       caseID: caseID,
                                       organizationID: organizationID, alertID: alertID,
                                       canManageDestinations: integration.destinationAdminProof.access?.canManage == true,
                                       liveDeliveryEnabled: liveEnabled)
    }

    func reportExport(caseID: String, evidenceIDs: [String], format: String, alertID: String,
                      caseDetail: IntelligenceCaseDetailEnvelope, snapshot: DwmCaseWorkflowSnapshot,
                      currentSettings: HanasandDesktopSettings) async throws -> [String: IntelligenceCaseJSON] {
        guard currentSettings == settings, let organizationID,
              IntelligenceCasesClient.validCaseID(caseID), caseDetail.caseRecord.id == caseID,
              caseDetail.alertContext["id"]?.stringValue == alertID,
              snapshot.caseID == caseID, snapshot.organizationID == organizationID, snapshot.alertID == alertID,
              ["json", "stix"].contains(format), !evidenceIDs.isEmpty, evidenceIDs.count <= 25,
              Set(evidenceIDs).count == evidenceIDs.count,
              evidenceIDs.allSatisfy({ id in snapshot.evidence.contains { $0["id"]?.stringValue == id } }) else {
            throw DwmCaseWorkflowError.invalidInput
        }

        var query = scopeQuery(alertID: alertID)
        query.append(URLQueryItem(name: "report", value: "true"))
        query.append(URLQueryItem(name: "format", value: format))
        evidenceIDs.sorted().forEach { query.append(URLQueryItem(name: "evidenceId", value: $0)) }
        let report = try await getJSON(service: .ti, path: "/v1/cases/\(encoded(caseID))/export", query: query)
        let policy = report["reportPolicy"]?.objectValue ?? [:]
        let policyEvidenceIDs = policy["evidenceIds"]?.arrayValue.map(\.stringValue) ?? []
        let expectedFormat = format == "stix" ? "stix-2.1" : "hanasand-json"
        guard let serialized = try? JSONSerialization.data(withJSONObject: report.mapValues(\.foundationValue), options: [.sortedKeys]) else {
            throw DwmCaseWorkflowError.malformedResponse
        }
        guard serialized.count <= 256_000,
              Self.reportContentMatches(report, format: format, evidenceCount: evidenceIDs.count),
              let checksum = report["exportChecksum"]?.stringValue,
              checksum.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              policy["direction"]?.stringValue == "outbound_third_party",
              policy["format"]?.stringValue == expectedFormat,
              policy["caseId"]?.stringValue == caseID,
              policy["alertId"]?.stringValue == alertID,
              policy["organizationId"]?.stringValue == organizationID,
              policy["exportChecksum"]?.stringValue == checksum,
              policy["evidenceCount"]?.numberValue == Double(evidenceIDs.count),
              policyEvidenceIDs == evidenceIDs.sorted() else {
            throw DwmCaseWorkflowError.malformedResponse
        }
        return report
    }

    private static func reportContentMatches(_ report: [String: IntelligenceCaseJSON], format: String, evidenceCount: Int) -> Bool {
        if format == "json" {
            return report["schemaVersion"]?.stringValue == "analyst.case_export.v1"
                && report["evidence"]?.arrayValue.count == evidenceCount
        }
        let bundle = report["bundle"]?.objectValue ?? [:]
        let objects = bundle["objects"]?.arrayValue.map(\.objectValue) ?? []
        let types = objects.compactMap { $0["type"]?.stringValue }
        let validation = report["standardsValidation"]?.objectValue ?? [:]
        return bundle["type"]?.stringValue == "bundle"
            && objects.count == evidenceCount + 2
            && types.filter { $0 == "identity" }.count == 1
            && types.filter { $0 == "report" }.count == 1
            && types.filter { $0 == "x-ti-evidence" }.count == evidenceCount
            && types.allSatisfy { ["identity", "report", "x-ti-evidence"].contains($0) }
            && validation["valid"] == .bool(true)
            && validation["standard"]?.stringValue == "STIX 2.1"
    }

    func notifyCustomerDryRun(caseID: String, note: String, currentSettings: HanasandDesktopSettings,
                              caseDetail: IntelligenceCaseDetailEnvelope,
                              scopeIsCurrent: @MainActor () -> Bool = { true }) async throws -> [String: IntelligenceCaseJSON] {
        guard currentSettings == settings, IntelligenceCasesClient.validCaseID(caseID), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.utf8.count <= 5_000, caseDetail.caseRecord.id == caseID, !caseDetail.readOnly,
              Self.rowMatchesScope(caseDetail.caseRecord, organizationID: organizationID, userID: settings.userID),
              caseDetail.actions.contains(where: { $0.enabled && $0.method.uppercased() == "PATCH" }) else { throw DwmCaseWorkflowError.invalidInput }
        var body: [String: Any] = ["tenantId": organizationID ?? settings.userID, "deliveryMode": "dry_run",
                                   "note": note.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "idempotencyKey": "desktop-case-notify:\(caseID):\(caseDetail.caseRecord.updatedAt.isEmpty ? caseDetail.caseRecord.createdAt : caseDetail.caseRecord.updatedAt)"]
        if let organizationID { body["organizationId"] = organizationID }
        let key = body["idempotencyKey"] as! String
        let response: DwmWorkflowHTTPResponse
        do { response = try await postJSON(service: .ti, path: "/v1/cases/\(encoded(caseID))/customer-notification", body: body, expectedSettings: currentSettings, scopeIsCurrent: scopeIsCurrent) }
        catch DwmCaseWorkflowError.uncertainOutcome(_) { throw DwmCaseWorkflowError.uncertainOutcome(key) }
        guard (200..<300).contains(response.statusCode) else { throw DwmCaseWorkflowError.uncertainOutcome(key) }
        let root = response.body
        guard let receipt = root["receipt"]?.objectValue, let id = receipt["id"]?.stringValue, !id.isEmpty else { throw DwmCaseWorkflowError.uncertainOutcome(key) }
        return receipt
    }

    func deliverReport(caseID: String, evidenceIDs: [String], format: String = "stix", destinationID: String,
                       alertID: String, dryRun: Bool, confirmedLive: Bool = false,
                       caseDetail: IntelligenceCaseDetailEnvelope, currentSettings: HanasandDesktopSettings,
                       scopeIsCurrent: @MainActor () -> Bool = { true }) async throws -> [String: IntelligenceCaseJSON] {
        guard currentSettings == settings, let organizationID,
              IntelligenceCasesClient.validCaseID(caseID), !alertID.isEmpty,
              ["json", "stix"].contains(format), !destinationID.isEmpty,
              !evidenceIDs.isEmpty, evidenceIDs.count <= 25, Set(evidenceIDs).count == evidenceIDs.count,
              caseDetail.caseRecord.id == caseID, !caseDetail.readOnly,
              Self.rowMatchesScope(caseDetail.caseRecord, organizationID: organizationID, userID: settings.userID),
              !caseDetail.actions.filter({ $0.enabled && $0.method.uppercased() == "PATCH" }).isEmpty,
              caseDetail.alertContext["id"]?.stringValue == alertID,
              dryRun || confirmedLive else { throw DwmCaseWorkflowError.invalidInput }

        let currentDetail = try await getJSON(service: .ti, path: "/v1/cases/\(encoded(caseID))", query: scopeQuery(alertID: alertID))
        if currentDetail["customerNotificationContext"]?["ready"] == .bool(false) {
            throw DwmCaseWorkflowError.invalidInput
        }
        if let policy = currentDetail["workflowActionPolicy"]?.objectValue,
           let summary = policy["summary"]?.objectValue,
           summary["readOnly"] == .bool(true) {
            throw DwmCaseWorkflowError.invalidInput
        }
        if !dryRun {
            let readiness = try await getJSON(service: .api, path: "/dwm/webhook-deliveries", query: [URLQueryItem(name: "orgId", value: organizationID)])
            guard readiness["deliveryOperations"]?["liveDeliveryEnabled"] == .bool(true) else { throw DwmCaseWorkflowError.invalidInput }
        }

        let alertRoot = try await getJSON(service: .ti, path: "/v1/dwm/alerts/\(encoded(alertID))", query: scopeQuery(alertID: nil))
        let alert = alertRoot["alert"]?.objectValue ?? alertRoot
        guard alert["id"]?.stringValue == alertID else { throw DwmCaseWorkflowError.malformedResponse }
        var reportQuery = scopeQuery(alertID: alertID)
        reportQuery.append(URLQueryItem(name: "report", value: "true"))
        reportQuery.append(URLQueryItem(name: "format", value: format))
        evidenceIDs.sorted().forEach { reportQuery.append(URLQueryItem(name: "evidenceId", value: $0)) }
        let report = try await getJSON(service: .ti, path: "/v1/cases/\(encoded(caseID))/export", query: reportQuery)
        guard let checksum = report["exportChecksum"]?.stringValue, checksum.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              report["reportPolicy"]?["alertId"]?.stringValue == alertID else { throw DwmCaseWorkflowError.malformedResponse }
        var boundAlert = alert
        boundAlert["caseId"] = .string(caseID)
        boundAlert["report"] = .object(report)
        boundAlert["dedupeKey"] = .string(checksum)
        boundAlert["evidenceCount"] = .number(Double(evidenceIDs.count))
        let integration = try await IntegrationClient(apiBaseURL: URL(string: settings.apiBaseURL)!, userID: settings.userID,
            token: settings.authToken, organizationID: organizationID, impersonationToken: settings.impersonationToken,
            impersonatingUserID: settings.impersonatingUserID, send: send).load()
        guard integration.destinationAdminProof.access?.canManage == true,
              integration.destinations.contains(where: { $0.id == destinationID && $0.orgId == organizationID && $0.status == "active" }) else {
            throw DwmCaseWorkflowError.invalidInput
        }
        let payload: [String: Any] = [
            "tenantId": organizationID, "organizationId": organizationID, "orgId": organizationID,
            "alertId": alertID, "alert": boundAlert.mapValues(\.foundationValue), "caseId": caseID,
            "evidenceIds": evidenceIDs.sorted(), "reportFormat": format, "destinationId": destinationID,
            "dryRun": dryRun, "live": !dryRun,
        ]
        let response: DwmWorkflowHTTPResponse
        do { response = try await postJSON(service: .api, path: "/dwm/webhook-deliveries", body: payload, expectedSettings: currentSettings, scopeIsCurrent: scopeIsCurrent) }
        catch DwmCaseWorkflowError.uncertainOutcome(_) { throw DwmCaseWorkflowError.uncertainOutcome(checksum) }
        let root = response.body
        guard let raw = root["deliveries"]?.arrayValue.first?.objectValue else { throw DwmCaseWorkflowError.uncertainOutcome(checksum) }
        let row: DwmWorkflowReceipt
        do { row = try JSONDecoder().decode(DwmWorkflowReceipt.self, from: JSONSerialization.data(withJSONObject: raw.mapValues(\.foundationValue))) }
        catch { throw DwmCaseWorkflowError.uncertainOutcome(checksum) }
        guard !row.id.isEmpty, row.organizationID == organizationID, row.alertID == alertID, row.caseID == caseID,
              row.destinationID == destinationID, row.thirdPartyReport,
              (response.statusCode == 502 && !dryRun && row.status == "failed"
                || (200..<300).contains(response.statusCode) && ((dryRun && row.status == "dry_run") || (!dryRun && row.status == "delivered"))) else {
            throw DwmCaseWorkflowError.uncertainOutcome(checksum)
        }
        return raw
    }

    func retryReport(delivery: [String: IntelligenceCaseJSON], caseID: String, alertID: String,
                     currentSettings: HanasandDesktopSettings, scopeIsCurrent: @MainActor () -> Bool = { true }) async throws -> [String: IntelligenceCaseJSON] {
        guard currentSettings == settings, let organizationID,
              DwmCaseWorkflowSnapshot.retryBlock(delivery, organizationID: organizationID, caseID: caseID, alertID: alertID) == nil,
              let deliveryID = delivery["deliveryId"]?.stringValue ?? delivery["id"]?.stringValue,
              ThreatDeliveryHistory.validID(deliveryID) else { throw DwmCaseWorkflowError.invalidInput }
        let before = try await load(caseID: caseID, alertID: alertID)
        guard before.liveDeliveryEnabled else { throw DwmCaseWorkflowError.invalidInput }
        guard let current = before.deliveries.first(where: { ($0["deliveryId"]?.stringValue ?? $0["id"]?.stringValue) == deliveryID }),
              DwmCaseWorkflowSnapshot.retryBlock(current, organizationID: organizationID, caseID: caseID, alertID: alertID) == nil else {
            throw DwmCaseWorkflowError.invalidInput
        }
        let body: [String: Any] = ["organizationId": organizationID, "deliveryId": deliveryID]
        let response: DwmWorkflowHTTPResponse
        do { response = try await postJSON(service: .api, path: "/dwm/webhook-deliveries", body: body, expectedSettings: currentSettings, scopeIsCurrent: scopeIsCurrent) }
        catch DwmCaseWorkflowError.uncertainOutcome(_) { throw DwmCaseWorkflowError.uncertainOutcome(deliveryID) }
        let root = response.body
        guard let receipt = root["deliveries"]?.arrayValue.first?.objectValue,
              (receipt["deliveryId"]?.stringValue ?? receipt["id"]?.stringValue) == deliveryID,
              receipt["orgId"]?.stringValue == organizationID,
              receipt["alertId"]?.stringValue == alertID,
              receipt["reportCaseId"]?.stringValue == caseID,
              (receipt["destinationId"]?.stringValue ?? receipt["webhookDestinationId"]?.stringValue) == (current["destinationId"]?.stringValue ?? current["webhookDestinationId"]?.stringValue),
              receipt["thirdPartyReport"] == .bool(true),
              (response.statusCode == 502 && receipt["status"]?.stringValue == "failed"
                || (200..<300).contains(response.statusCode)) else { throw DwmCaseWorkflowError.uncertainOutcome(deliveryID) }
        let after = try await load(caseID: caseID, alertID: alertID)
        guard let refreshed = after.deliveries.first(where: { ($0["deliveryId"]?.stringValue ?? $0["id"]?.stringValue) == deliveryID }),
              refreshed["orgId"]?.stringValue == organizationID, refreshed["alertId"]?.stringValue == alertID,
              refreshed["reportCaseId"]?.stringValue == caseID, refreshed["thirdPartyReport"] == .bool(true),
              refreshed["status"]?.stringValue == receipt["status"]?.stringValue,
              refreshed["attemptedAt"]?.stringValue != current["attemptedAt"]?.stringValue
                || (refreshed["attemptCount"]?.numberValue ?? 0) > (current["attemptCount"]?.numberValue ?? 0) else {
            throw DwmCaseWorkflowError.uncertainOutcome(deliveryID)
        }
        return refreshed
    }

    private enum Service { case api, ti }

    private func getJSON(service: Service, path: String, query: [URLQueryItem]) async throws -> [String: IntelligenceCaseJSON] {
        var components = try urlComponents(service: service, path: path)
        components.queryItems = query.isEmpty ? nil : query
        return try await requestJSON(components, method: "GET")
    }

    private func postJSON(service: Service, path: String, body: [String: Any], expectedSettings: HanasandDesktopSettings,
                          scopeIsCurrent: @MainActor () -> Bool) async throws -> DwmWorkflowHTTPResponse {
        var components = try urlComponents(service: service, path: path)
        components.queryItems = scopeQuery(alertID: nil)
        guard let url = components.url else { throw DwmCaseWorkflowError.invalidEndpoint }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= Self.responseLimit else { throw DwmCaseWorkflowError.invalidInput }
        var request = makeRequest(url, method: "POST")
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard expectedSettings == settings, await scopeIsCurrent() else { throw DwmCaseWorkflowError.scopeChanged }
        return try await requestJSON(request, uncertainOnFailure: true)
    }

    private func requestJSON(_ components: URLComponents, method: String) async throws -> [String: IntelligenceCaseJSON] {
        guard let url = components.url else { throw DwmCaseWorkflowError.invalidEndpoint }
        let response = try await requestJSON(makeRequest(url, method: method))
        guard (200..<300).contains(response.statusCode) else { throw DwmCaseWorkflowError.requestFailed(response.statusCode) }
        return response.body
    }

    private func requestJSON(_ request: URLRequest, uncertainOnFailure: Bool = false) async throws -> DwmWorkflowHTTPResponse {
        do {
            let (data, raw) = try await send(request)
            guard data.count <= Self.responseLimit, let http = raw as? HTTPURLResponse, http.url == request.url,
                  let root = try? JSONDecoder().decode([String: IntelligenceCaseJSON].self, from: data) else {
                throw uncertainOnFailure ? DwmCaseWorkflowError.uncertainOutcome("") : DwmCaseWorkflowError.malformedResponse
            }
            if !(200..<300).contains(http.statusCode) {
                if uncertainOnFailure && http.statusCode >= 500 {
                    guard http.statusCode == 502 else { throw DwmCaseWorkflowError.uncertainOutcome("") }
                    return DwmWorkflowHTTPResponse(statusCode: http.statusCode, body: root)
                }
                throw DwmCaseWorkflowError.requestFailed(http.statusCode)
            }
            return DwmWorkflowHTTPResponse(statusCode: http.statusCode, body: root)
        } catch let error as DwmCaseWorkflowError { throw error }
        catch { throw uncertainOnFailure ? DwmCaseWorkflowError.uncertainOutcome("") : DwmCaseWorkflowError.malformedResponse }
    }

    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        if let organizationID {
            request.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
            request.setValue(organizationID, forHTTPHeaderField: "x-tenant-id")
        }
        return request
    }

    private func urlComponents(service: Service, path: String) throws -> URLComponents {
        let base: URL?
        switch service {
        case .api: base = settings.apiBaseURL.normalizedBaseURL
        case .ti:
            let site = URL(string: settings.websiteBaseURL)
            base = site?.host?.lowercased() == "hanasand.com" ? URL(string: "https://ti.hanasand.com") : site
        }
        guard let base, base.scheme?.lowercased() == "https", let host = base.host,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw DwmCaseWorkflowError.invalidEndpoint }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = nil
        components.fragment = nil
        guard let url = components.url, url.host == host, url.scheme == "https" else { throw DwmCaseWorkflowError.invalidEndpoint }
        return components
    }

    private func scopeQuery(alertID: String?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "tenantId", value: organizationID ?? settings.userID)]
        if let organizationID { query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        if let alertID, !alertID.isEmpty { query.append(URLQueryItem(name: "alertId", value: alertID)) }
        return query
    }

    private func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "" }
    private func rows(_ object: [String: IntelligenceCaseJSON], keys: [String]) -> [[String: IntelligenceCaseJSON]] {
        for key in keys { if case .array(let rows) = object[key] { return rows.map(\.objectValue) } }
        return []
    }

    private static func scopeMatches(_ row: [String: IntelligenceCaseJSON], organizationID: String?, userID: String) -> Bool {
        let expected = organizationID ?? userID
        let tenant = row["tenantId"]?.stringValue ?? ""
        let organization = row["organizationId"]?.stringValue ?? ""
        return (tenant.isEmpty || tenant == expected) && (organization.isEmpty || organization == expected)
    }

    private static func rowMatchesScope(_ row: IntelligenceCaseRow, organizationID: String?, userID: String) -> Bool {
        let expected = organizationID ?? userID
        return (row.tenantID.isEmpty || row.tenantID == expected) && (row.organizationID.isEmpty || row.organizationID == expected)
    }
}

private struct DwmWorkflowHTTPResponse {
    let statusCode: Int
    let body: [String: IntelligenceCaseJSON]
}

private struct DwmWorkflowReceipt: Decodable {
    let id: String
    let organizationID: String
    let alertID: String
    let caseID: String
    let destinationID: String
    let thirdPartyReport: Bool
    let status: String
    enum CodingKeys: String, CodingKey {
        case id
        case organizationID = "orgId"
        case alertID = "alertId"
        case caseID = "reportCaseId"
        case destinationID = "destinationId"
        case thirdPartyReport
        case status
    }
}

extension IntelligenceCaseJSON {
    var numberValue: Double { if case .number(let value) = self { value } else { 0 } }
    var foundationValue: Any {
        switch self {
        case .object(let value): value.mapValues(\.foundationValue)
        case .array(let value): value.map(\.foundationValue)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }
}

private final class DwmCaseWorkflowRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
