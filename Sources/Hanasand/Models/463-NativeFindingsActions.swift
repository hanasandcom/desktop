import Foundation

enum NativeFindingsAction: String, CaseIterable, Identifiable {
    case saveWatchlist, runCollection, testWebhook, deliverWebhooks, submitTelegramSource, ingestAdvisory, openCase
    var id: String { rawValue }
    var title: String {
        switch self {
        case .saveWatchlist: "Save watchlist"
        case .runCollection: "Run collection"
        case .testWebhook: "Test webhook"
        case .deliverWebhooks: "Send queued findings"
        case .submitTelegramSource: "Submit Telegram source"
        case .ingestAdvisory: "Ingest public advisory"
        case .openCase: "Open case from advisory"
        }
    }
}

struct NativeFindingsActionInput: Equatable {
    var terms = ""
    var webhookURL = ""
    var telegramTarget = ""
    var actor = ""
    var company = ""
    var claimedData = ""
    var sourceURL = ""
}

struct NativeFindingsActionReceipt: Equatable {
    let action: NativeFindingsAction
    let message: String
    let detail: String?
    let isWarning: Bool
}

enum NativeFindingsActionsError: LocalizedError, Equatable {
    case signInRequired, impersonationUnsupported, invalidScope, invalidInput(String)
    case permissionDenied, requestFailed(Int, String), uncertainOutcome, partialOutcome(String), invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to use findings actions."
        case .impersonationUnsupported: "Findings actions are disabled while impersonating. Return to your account first."
        case .invalidScope: "The selected workspace changed. Refresh findings and try again."
        case .invalidInput(let message): message
        case .permissionDenied: "Your current workspace role cannot perform this action. Ask an organization owner or administrator."
        case .requestFailed(let status, let message): status == 403 ? "Access denied: \(message)" : message
        case .uncertainOutcome: "The server did not confirm whether this action finished. Refresh the workspace before retrying."
        case .partialOutcome(let message): message
        case .invalidResponse: "The server returned an invalid or incomplete action receipt. Refresh before retrying."
        }
    }
}

/// Native HTTP client for the same first-party endpoints used by the website's Findings Actions workflow.
/// Requests never follow redirects, carry no cookies, and are fenced to the configured HTTPS origin.
struct NativeFindingsActionsClient {
    let baseURL: URL
    let tenantID: String
    let organizationID: String?
    let userID: String
    let token: String
    let impersonationClear: Bool
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await NativeFindingsActionsSession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw NativeFindingsActionsError.signInRequired }
        guard settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeFindingsActionsError.impersonationUnsupported
        }
        guard user.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              token.range(of: #"^[A-Za-z0-9._~-]{1,4096}$"#, options: .regularExpression) != nil else {
            throw NativeFindingsActionsError.signInRequired
        }
        let base = settings.websiteBaseURL.normalizedBaseURL
        guard base.scheme?.lowercased() == "https", base.host != nil, base.user == nil, base.password == nil else {
            throw NativeFindingsActionsError.invalidScope
        }
        let rawSelection = settings.selectedOrganizationID
        let org: String? = rawSelection.isEmpty || rawSelection == "personal" || rawSelection == user ? nil : rawSelection
        if let org {
            guard org.range(of: #"^[A-Za-z0-9_.:@-]{1,200}$"#, options: .regularExpression) != nil,
                  settings.selectedOrganizationUserID == user else { throw NativeFindingsActionsError.invalidScope }
        }
        self.baseURL = base
        self.tenantID = org ?? user
        self.organizationID = org
        self.userID = user
        self.token = token
        self.impersonationClear = settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty
        if let send { self.send = send }
    }

    func perform(_ action: NativeFindingsAction, input: NativeFindingsActionInput,
                 contextIsCurrent: @MainActor () -> Bool = { true }) async throws -> NativeFindingsActionReceipt {
        guard impersonationClear, await contextIsCurrent() else { throw NativeFindingsActionsError.invalidScope }
        let scope: [String: Any] = ["tenantId": tenantID].merging(organizationID.map { ["organizationId": $0] } ?? [:]) { _, new in new }
        if action == .ingestAdvisory || action == .openCase {
            return try await performAdvisory(action, input: input, scope: scope, contextIsCurrent: contextIsCurrent)
        }
        var endpoint: String
        var body = scope
        var success: String
        var detail: String?
        var warning = false
        switch action {
        case .saveWatchlist:
            let values = normalizedTerms(input.terms)
            guard !values.isEmpty else { throw NativeFindingsActionsError.invalidInput("Add at least one watchlist term before saving.") }
            endpoint = "api/findings/watchlists"
            body.merge(["name": "Default company exposure watchlist", "terms": values]) { _, new in new }
            if !input.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["webhookUrl"] = try validatedWebhook(input.webhookURL) }
            success = "Watchlist terms saved."
        case .runCollection:
            endpoint = "api/findings/canary/run"
            body.merge(["operatorApproval": true, "approvedBy": "dashboard", "maxSources": 12, "maxTasks": 24]) { _, new in new }
            success = "Collection run accepted. Refresh findings to review its results."
            warning = true
        case .testWebhook:
            endpoint = "api/findings/webhooks/test"
            let url = try validatedWebhook(input.webhookURL)
            body["webhookUrl"] = url
            success = "Webhook test recorded. Review delivery history for the result."
        case .deliverWebhooks:
            endpoint = "api/findings/webhooks/deliver"
            if !input.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["webhookUrl"] = try validatedWebhook(input.webhookURL) }
            body["limit"] = 25
            success = "Delivery request accepted. Review delivery history to confirm delivered, dry-run, or skipped events."
            warning = true
        case .submitTelegramSource:
            let target = input.telegramTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            guard target.range(of: #"^(@[A-Za-z0-9_]{5,32}|https://t\.me/[A-Za-z0-9_]{5,32}/?)$"#, options: .regularExpression) != nil else {
                throw NativeFindingsActionsError.invalidInput("Enter a public Telegram handle or https://t.me/channel URL.")
            }
            endpoint = "api/findings/source-requests"
            body.merge(["target": target, "type": "telegram_channel", "priority": "high", "scope": normalizedTerms(input.terms), "activate": false]) { _, new in new }
            success = "Telegram source request submitted for review."
        case .ingestAdvisory:
            let advisory = try validatedAdvisory(input)
            endpoint = "api/findings/exposure-claims/ingest"
            body = ["items": [["tenantId": tenantID, "organizationId": organizationID as Any? ?? NSNull(), "company": advisory.company,
                "claimedData": advisory.claimedData, "sourceName": "\(advisory.actor) public report", "sourceFamily": "public_advisory",
                "title": "\(advisory.actor) reported a new issue involving \(advisory.company)",
                "text": "\(advisory.actor) reported an issue involving \(advisory.company). \(advisory.claimedData).", "url": advisory.url]]]
            if organizationID == nil, var first = (body["items"] as? [[String: Any]])?.first { first.removeValue(forKey: "organizationId"); body["items"] = [first] }
            success = "Public advisory evidence submitted. Refresh findings to review the result."
            warning = true
        case .openCase:
            throw NativeFindingsActionsError.invalidInput("Enter advisory details before opening a case.")
        }
        let result = try await post(path: endpoint, body: body, contextIsCurrent: contextIsCurrent)
        if action == .submitTelegramSource {
            let requestID = nestedString(result, keys: ["request", "id"])
            let sourceID = nestedString(result, keys: ["source", "id"])
            let duplicate = string(result["duplicateOf"])
            guard !requestID.isEmpty, !sourceID.isEmpty || !duplicate.isEmpty else { throw NativeFindingsActionsError.invalidResponse }
            detail = duplicate.isEmpty ? requestID : "Already registered as \(duplicate)."
        } else if action == .openCase {
            let caseID = string(nestedValue(result, keys: ["case", "id"])).isEmpty
                ? string(nestedValue(result, keys: ["alertCaseHandoff", "caseId"]))
                : string(nestedValue(result, keys: ["case", "id"]))
            guard !caseID.isEmpty else { throw NativeFindingsActionsError.invalidResponse }
            detail = "Case \(caseID)"
        } else if action == .runCollection {
            let rebuild = try await post(path: "api/findings/alerts/rebuild", body: scope, contextIsCurrent: contextIsCurrent)
            let captures = number(nestedValue(result, keys: ["canaryRun", "insertedCaptureCount"])) ?? 0
            let matches = number(rebuild["savedAlertCount"]) ?? array(rebuild["alerts"]).count
            detail = "\(captures) captures collected · \(matches) matching events."
        } else if action == .testWebhook || action == .deliverWebhooks {
            let rows = array(result["deliveries"])
            guard !rows.isEmpty else { throw NativeFindingsActionsError.invalidResponse }
            let failed = rows.contains { ($0["status"] as? String) == "failed" || $0["error"] != nil && !($0["error"] is NSNull) }
            let dryRun = rows.contains { ($0["status"] as? String) == "dry_run" || ($0["dryRun"] as? Bool) == true }
            let delivered = rows.filter { ($0["status"] as? String) == "delivered" && ($0["dryRun"] as? Bool) != true }.count
            detail = failed ? "A delivery attempt failed. Review delivery history before retrying."
                : delivered > 0 ? "\(delivered) event\(delivered == 1 ? "" : "s") delivered."
                : dryRun ? "Dry-run recorded; no customer notification was sent."
                : "Delivery was skipped or remains unconfirmed. Review delivery history."
            warning = failed || delivered == 0
        }
        return NativeFindingsActionReceipt(action: action, message: success, detail: detail, isWarning: warning)
    }

    private func performAdvisory(_ action: NativeFindingsAction, input: NativeFindingsActionInput,
                                 scope: [String: Any], contextIsCurrent: @MainActor () -> Bool) async throws -> NativeFindingsActionReceipt {
        let advisory = try validatedAdvisory(input)
        let acceptedPayload: [String: Any]
        do {
            acceptedPayload = try await post(path: "api/findings/exposure-claims/ingest", body: ["items": [[
                "tenantId": tenantID, "company": advisory.company, "claimedData": advisory.claimedData,
                "sourceName": "\(advisory.actor) public report", "sourceFamily": "public_advisory",
                "title": "\(advisory.actor) reported a new issue involving \(advisory.company)",
                "text": "\(advisory.actor) reported an issue involving \(advisory.company). \(advisory.claimedData).", "url": advisory.url
            ].merging(organizationID.map { ["organizationId": $0] } ?? [:]) { _, new in new }]], contextIsCurrent: contextIsCurrent)
        } catch { throw error }
        guard let accepted = number(acceptedPayload["accepted"]), accepted > 0 else { throw NativeFindingsActionsError.invalidResponse }

        var terms = normalizedTerms(input.terms)
        if !terms.contains(where: { $0.caseInsensitiveCompare(advisory.company) == .orderedSame }) { terms.append(advisory.company) }
        do {
            var watchlist: [String: Any] = scope
            watchlist.merge(["name": "Default company exposure watchlist", "terms": terms]) { _, new in new }
            if !input.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { watchlist["webhookUrl"] = try validatedWebhook(input.webhookURL) }
            _ = try await post(path: "api/findings/watchlists", body: watchlist, contextIsCurrent: contextIsCurrent)
        } catch { throw NativeFindingsActionsError.partialOutcome("\(accepted) evidence item was accepted, but the watchlist update did not finish. Refresh the watchlist before continuing. \(error.localizedDescription)") }

        let rebuild: [String: Any]
        do { rebuild = try await post(path: "api/findings/alerts/rebuild", body: scope, contextIsCurrent: contextIsCurrent) }
        catch { throw NativeFindingsActionsError.partialOutcome("Evidence and watchlist updates may be saved, but matching events were not confirmed. Refresh findings before retrying. \(error.localizedDescription)") }
        if action == .ingestAdvisory {
            let count = number(rebuild["savedAlertCount"]) ?? array(rebuild["alerts"]).count
            return NativeFindingsActionReceipt(action: action, message: "Public advisory evidence submitted.", detail: "\(accepted) evidence item accepted · \(count) matching events.", isWarning: count == 0)
        }

        let needles = [advisory.company] + terms
        let alerts = array(rebuild["alerts"])
        let matching = alerts.first { alert in
            let company = string(alert["company"]).lowercased()
            let matched = string(nestedValue(alert, keys: ["matchedTerm", "value"])).lowercased()
            let summary = string(alert["claimSummary"]).lowercased()
            return needles.contains { needle in
                let value = needle.lowercased()
                return company.contains(value) || matched.contains(value) || summary.contains(value)
            }
        } ?? alerts.first
        guard let alertID = matching.map({ string($0["id"]) }), !alertID.isEmpty else {
            throw NativeFindingsActionsError.partialOutcome("Evidence was accepted and the watchlist was updated, but no matching finding was returned. Refresh findings before opening a case.")
        }
        let encodedAlert = alertID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
        let casePayload: [String: Any]
        do {
            var handoff = scope
            handoff.merge(["actor": "desktop", "note": "Case opened from public incident evidence for \(advisory.company).",
                "idempotencyKey": "dashboard-public-advisory-case:\(alertID)"]) { _, new in new }
            casePayload = try await post(path: "api/findings/alerts/\(encodedAlert)/case-handoff", body: handoff, contextIsCurrent: contextIsCurrent)
        } catch { throw NativeFindingsActionsError.partialOutcome("Evidence and matching finding are saved, but case creation was not confirmed. Refresh the finding before retrying. \(error.localizedDescription)") }
        let caseID = string(nestedValue(casePayload, keys: ["case", "id"])).isEmpty
            ? string(nestedValue(casePayload, keys: ["alertCaseHandoff", "caseId"]))
            : string(nestedValue(casePayload, keys: ["case", "id"]))
        guard !caseID.isEmpty else { throw NativeFindingsActionsError.partialOutcome("Evidence and the matching finding are saved, but the server returned no case ID. Refresh cases before retrying.") }
        var detail = "Evidence \(accepted) · finding \(alertID) · case \(caseID)."
        if !input.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                var delivery: [String: Any] = scope
                delivery.merge(["alertId": alertID, "caseId": caseID, "limit": 1, "dryRun": true,
                    "webhookUrl": try validatedWebhook(input.webhookURL), "attachToWatchlist": true]) { _, new in new }
                let result = try await post(path: "api/findings/webhooks/deliver", body: delivery, contextIsCurrent: contextIsCurrent)
                let rows = array(result["deliveries"])
                guard !rows.isEmpty else { throw NativeFindingsActionsError.invalidResponse }
                detail += rows.contains { ($0["status"] as? String) == "delivered" && ($0["dryRun"] as? Bool) != true }
                    ? " Delivery sent."
                    : " Dry-run recorded; no customer notification was sent."
            } catch {
                throw NativeFindingsActionsError.partialOutcome("Case \(caseID) was created, but its dry-run delivery was not confirmed. Review delivery history. \(error.localizedDescription)")
            }
        }
        return NativeFindingsActionReceipt(action: action, message: "Case \(caseID) opened from public advisory evidence.", detail: detail, isWarning: false)
    }

    private func post(path: String, body: [String: Any], contextIsCurrent: @MainActor () -> Bool) async throws -> [String: Any] {
        guard await contextIsCurrent() else { throw NativeFindingsActionsError.invalidScope }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw NativeFindingsActionsError.invalidScope }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, path].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url, url.scheme == "https", url.host == baseURL.host else { throw NativeFindingsActionsError.invalidScope }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if let organizationID { request.setValue(organizationID, forHTTPHeaderField: "x-organization-id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data: Data, raw: URLResponse
        do { (data, raw) = try await send(request) }
        catch { throw NativeFindingsActionsError.uncertainOutcome }
        guard data.count <= 1_000_000, let response = raw as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == baseURL.host, response.url?.path == url.path else {
            throw NativeFindingsActionsError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 { throw NativeFindingsActionsError.permissionDenied }
            if response.statusCode == 408 || response.statusCode >= 500 { throw NativeFindingsActionsError.uncertainOutcome }
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = payload?["error"] as? [String: Any]
            throw NativeFindingsActionsError.requestFailed(response.statusCode, error?["message"] as? String ?? "Request failed (HTTP \(response.statusCode)).")
        }
        guard await contextIsCurrent() else { throw NativeFindingsActionsError.invalidScope }
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw NativeFindingsActionsError.invalidResponse }
        return payload
    }

    private func validatedWebhook(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { throw NativeFindingsActionsError.invalidInput("Enter a valid HTTPS webhook URL.") }
        return value
    }

    private func validatedAdvisory(_ input: NativeFindingsActionInput) throws -> (actor: String, company: String, claimedData: String, url: String) {
        let actor = input.actor.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = input.company.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = input.claimedData.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = input.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty, actor.count <= 160, !company.isEmpty, company.count <= 200,
              !data.isEmpty, data.count <= 4000, let url = URL(string: source), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw NativeFindingsActionsError.invalidInput("Enter the actor, affected company, exposure details, and an HTTPS source URL.")
        }
        return (actor, company, data, source)
    }

    private func normalizedTerms(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split { $0.isNewline || $0 == "," }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    private func nestedValue(_ object: [String: Any], keys: [String]) -> Any? {
        var value: Any = object
        for key in keys { guard let next = (value as? [String: Any])?[key] else { return nil }; value = next }
        return value
    }
    private func nestedString(_ object: [String: Any], keys: [String]) -> String { string(nestedValue(object, keys: keys)) }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func number(_ value: Any?) -> Int? { value as? Int }
    private func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
}

private final class NativeFindingsActionsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum NativeFindingsActionsSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NativeFindingsActionsRedirectBlocker(), delegateQueue: nil)
    }()
}
