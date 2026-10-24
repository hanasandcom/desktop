import CryptoKit
import Foundation

private final class OrganizationPrivacyRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum OrganizationPrivacySession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: OrganizationPrivacyRedirectDelegate(), delegateQueue: nil)
    }()
}

final class OrganizationPrivacyIntentRegistry {
    private let lock = NSLock()
    private var pending: [String: OrganizationPrivacyIntent] = [:]
    private var key: String { "\(baseURL.absoluteString)|\(userID)|\(organizationID)" }
    let baseURL: URL
    let userID: String
    let organizationID: String

    init(baseURL: URL, userID: String, organizationID: String) {
        self.baseURL = baseURL; self.userID = userID; self.organizationID = organizationID
    }

    func claim(_ intent: OrganizationPrivacyIntent) throws {
        lock.lock(); defer { lock.unlock() }
        guard pending[key] == nil else { throw OrganizationPrivacyError.duplicateSubmission }
        pending[key] = intent
    }
    func resolve(_ intent: OrganizationPrivacyIntent) {
        lock.lock(); defer { lock.unlock() }
        if pending[key] == intent { pending[key] = nil }
    }
    func unresolved() -> OrganizationPrivacyIntent? {
        lock.lock(); defer { lock.unlock() }
        return pending[key]
    }
}

struct OrganizationPrivacyClient {
    let baseURL: URL
    let organizationID: String
    let userID: String
    let authToken: String
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private let registry: OrganizationPrivacyIntentRegistry
    private let updateRegistry: (OrganizationPrivacyIntent?, Bool) -> Void

    init(settings: HanasandDesktopSettings, organizationID: String,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         registry: OrganizationPrivacyIntentRegistry? = nil,
         updateRegistry: @escaping (OrganizationPrivacyIntent?, Bool) -> Void = { _, _ in }) throws {
        let base = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw OrganizationPrivacyError.invalidBaseURL }
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw OrganizationPrivacyError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else { throw OrganizationPrivacyError.invalidCredentials }
        guard !organizationID.isEmpty, organizationID != "personal", settings.selectedOrganizationID == organizationID,
              settings.selectedOrganizationUserID == user else { throw OrganizationPrivacyError.organizationScopeChanged }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationPrivacyError.impersonationUnsupported
        }
        self.baseURL = url; self.organizationID = organizationID; self.userID = user; self.authToken = token
        self.send = send ?? { try await OrganizationPrivacySession.shared.data(for: $0) }
        self.registry = registry ?? OrganizationPrivacyIntentRegistry(baseURL: url, userID: user, organizationID: organizationID)
        self.updateRegistry = updateRegistry
    }

    func load(offset: Int = 0) async throws -> OrganizationPrivacySnapshot {
        guard (0...100_000).contains(offset), offset % 50 == 0 else { throw OrganizationPrivacyError.invalidOffset }
        let (data, http) = try await request(method: "GET", offset: offset, body: nil)
        guard (200..<300).contains(http.statusCode) else { throw apiError(http.statusCode, data) }
        let state: OrganizationPrivacySnapshot
        do { state = try JSONDecoder().decode(OrganizationPrivacySnapshot.self, from: data) } catch { throw OrganizationPrivacyError.invalidResponse }
        try state.validate(organizationID: organizationID, requestedOffset: offset)
        return state
    }

    func perform(_ action: OrganizationPrivacyAction, requestID: String, expectedName: String,
                 deletionName: String? = nil, currentPassword: String? = nil) async throws -> OrganizationPrivacyActionReceipt {
        guard requestID.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil else { throw OrganizationPrivacyError.invalidAction }
        let intent = OrganizationPrivacyIntent(action: action, requestID: requestID)
        try registry.claim(intent)
        updateRegistry(intent, false)
        var postStarted = false
        do {
            let fresh = try await load()
            guard fresh.organization.name == expectedName, let permissions = fresh.permissions, permissions.allows(action) else {
                throw OrganizationPrivacyError.permissionDenied
            }
            var body: [String: Any] = ["action": action.rawValue, "requestId": requestID]
            if action == .delete {
                guard deletionName == fresh.organization.name, let currentPassword, !currentPassword.isEmpty else {
                    throw OrganizationPrivacyError.invalidDeletionConfirmation
                }
                body["confirmation"] = fresh.organization.name
                body["currentPassword"] = currentPassword
            }
            let encoded = try JSONSerialization.data(withJSONObject: body)
            postStarted = true
            let (data, http) = try await request(method: "POST", offset: 0, body: encoded)
            if (200..<300).contains(http.statusCode) || http.statusCode == 502 {
                let receipt = try decodeReceipt(data, action: action, requestID: requestID, httpStatus: http.statusCode)
                if action == .export {
                    guard let serverRecordID = receipt.serverRecordID else {
                        throw OrganizationPrivacyError.unconfirmedOutcome
                    }
                    let history: OrganizationPrivacySnapshot
                    do { history = try await load() }
                    catch { throw OrganizationPrivacyError.unconfirmedOutcome }
                    guard history.requests.contains(where: {
                        $0.id == serverRecordID
                            && $0.organizationID == organizationID
                            && $0.requestID == requestID
                            && $0.requestType == "export"
                            && $0.status == receipt.status
                    }) else { throw OrganizationPrivacyError.unconfirmedOutcome }
                }
                registry.resolve(intent); updateRegistry(nil, true)
                return receipt
            }
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                throw apiError(http.statusCode, data)
            }
            throw OrganizationPrivacyError.unconfirmedOutcome
        } catch {
            // Explicit client-side or authorization rejection is definite. A transport or
            // service error can have committed, so keep the idempotency key locked.
            if !postStarted {
                registry.resolve(intent); updateRegistry(nil, true)
            } else if error is OrganizationPrivacyError, case OrganizationPrivacyError.permissionDenied = error {
                registry.resolve(intent); updateRegistry(nil, true)
            } else if error is OrganizationPrivacyError, case OrganizationPrivacyError.invalidDeletionConfirmation = error {
                registry.resolve(intent); updateRegistry(nil, true)
            } else if error is OrganizationPrivacyError, case OrganizationPrivacyError.requestFailed(let status, _) = error, (400...499).contains(status), status != 409 {
                registry.resolve(intent); updateRegistry(nil, true)
            }
            throw error
        }
    }

    func reconcile(_ intent: OrganizationPrivacyIntent) async throws -> OrganizationPrivacySnapshot.Record? {
        let state = try await load()
        return OrganizationPrivacyReconciliation.matchingRecord(in: state, intent: intent)
    }

    private func decodeReceipt(_ bytes: Data, action: OrganizationPrivacyAction, requestID: String, httpStatus: Int) throws -> OrganizationPrivacyActionReceipt {
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw OrganizationPrivacyError.unconfirmedOutcome }
        if action == .export {
            guard let req = root["request"] as? [String: Any],
                  let serverRecordID = req["id"] as? String,
                  !serverRecordID.isEmpty else { throw OrganizationPrivacyError.unconfirmedOutcome }
            if httpStatus == 502 {
                guard req["status"] as? String == "failed" else { throw OrganizationPrivacyError.unconfirmedOutcome }
                return OrganizationPrivacyActionReceipt(action: action, requestID: requestID, status: "failed", state: nil,
                                                        exportFile: nil, checksum: nil, serverRecordID: serverRecordID)
            }
            guard httpStatus == 200 else { throw OrganizationPrivacyError.unconfirmedOutcome }
            let raw = Array(bytes)
            guard let exportRange = memberRange(named: "export", in: 0..<raw.count, bytes: raw),
                  let dataRange = memberRange(named: "data", in: exportRange, bytes: raw),
                  let fileRange = try? JSONDecoder().decode(OrganizationPrivacyExport.self, from: Data(raw[exportRange])),
                  req["status"] as? String == "completed" else { throw OrganizationPrivacyError.unconfirmedOutcome }
            let file = Data(raw[exportRange])
            let actualChecksum = SHA256.hash(data: Data(raw[dataRange])).map { String(format: "%02x", $0) }.joined()
            guard actualChecksum == fileRange.checksum else { throw OrganizationPrivacyError.unconfirmedOutcome }
            let export = fileRange
            try export.validate(organizationID: organizationID)
            return OrganizationPrivacyActionReceipt(action: action, requestID: requestID, status: "completed", state: nil, exportFile: file, checksum: export.checksum, serverRecordID: serverRecordID)
        }
        // POST returns a bare privacy_state body; preserve the 100-item POST page contract.
        let state = try JSONDecoder().decode(OrganizationPrivacySnapshot.self, from: bytes)
        try state.validate(organizationID: organizationID, requestedOffset: 0, requirePermissions: false, expectedLimit: 100)
        let worker = root["worker"] as? [String: Any]
        guard let worker, let run = state.runs.first(where: { $0.requestID == requestID }),
              run.triggerType == (action == .delete ? "privacy_deletion" : "manual"),
              ["completed", "running", "queued", "failed", "dead_letter"].contains(run.status ?? ""),
              worker["runId"] as? String == run.id else { throw OrganizationPrivacyError.unconfirmedOutcome }
        let status = run.status ?? ""
        if action == .delete {
            guard let request = state.requests.first(where: { $0.requestID == requestID && $0.requestType == "deletion" }),
                  run.privacyRequestID == request.id else { throw OrganizationPrivacyError.unconfirmedOutcome }
        }
        guard (httpStatus == 502) == ["failed", "dead_letter"].contains(status), httpStatus != 409 else { throw OrganizationPrivacyError.unconfirmedOutcome }
        return OrganizationPrivacyActionReceipt(action: action, requestID: requestID, status: status, state: state, exportFile: nil, checksum: nil, serverRecordID: nil)
    }

    private func request(method: String, offset: Int, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let segment = organizationID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw OrganizationPrivacyError.invalidBaseURL }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, "organizations/\(segment)/privacy"].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = method == "GET" ? [URLQueryItem(name: "itemOffset", value: String(offset)), URLQueryItem(name: "itemLimit", value: "50")] : nil
        guard let url = components.url, url.scheme == "https", url.host == baseURL.host else { throw OrganizationPrivacyError.invalidBaseURL }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await send(request)
        guard data.count <= 16 * 1024 * 1024, let http = response as? HTTPURLResponse else { throw OrganizationPrivacyError.unconfirmedOutcome }
        return (data, http)
    }
    private func apiError(_ status: Int, _ data: Data) -> OrganizationPrivacyError {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String ?? "The privacy request was rejected."
        return .requestFailed(status, message)
    }

    // Locate a direct JSON object member without re-encoding its value. The API checksum
    // is computed over JSON.stringify(data), whose object key order must be preserved.
    private func memberRange(named name: String, in range: Range<Int>, bytes: [UInt8]) -> Range<Int>? {
        var cursor = range.lowerBound
        skipWhitespace(&cursor, bytes)
        guard cursor < range.upperBound, bytes[cursor] == 123 else { return nil }
        cursor += 1
        while cursor < range.upperBound {
            skipWhitespace(&cursor, bytes)
            if cursor < range.upperBound, bytes[cursor] == 125 { return nil }
            guard let keyRange = valueRange(cursor, range.upperBound, bytes),
                  let key = try? JSONDecoder().decode(String.self, from: Data(bytes[keyRange])) else { return nil }
            cursor = keyRange.upperBound
            skipWhitespace(&cursor, bytes)
            guard cursor < range.upperBound, bytes[cursor] == 58 else { return nil }
            cursor += 1; skipWhitespace(&cursor, bytes)
            guard let value = valueRange(cursor, range.upperBound, bytes) else { return nil }
            if key == name { return value }
            cursor = value.upperBound; skipWhitespace(&cursor, bytes)
            guard cursor < range.upperBound, bytes[cursor] == 44 else { return nil }
            cursor += 1
        }
        return nil
    }

    private func valueRange(_ start: Int, _ limit: Int, _ bytes: [UInt8]) -> Range<Int>? {
        guard start < limit else { return nil }
        if bytes[start] == 34 {
            var i = start + 1; var escaped = false
            while i < limit {
                if escaped { escaped = false }
                else if bytes[i] == 92 { escaped = true }
                else if bytes[i] == 34 { return start..<(i + 1) }
                i += 1
            }
            return nil
        }
        if bytes[start] == 123 || bytes[start] == 91 {
            var depth = 0; var inString = false; var escaped = false
            for i in start..<limit {
                let b = bytes[i]
                if inString {
                    if escaped { escaped = false }
                    else if b == 92 { escaped = true }
                    else if b == 34 { inString = false }
                } else if b == 34 { inString = true }
                else if b == 123 || b == 91 { depth += 1 }
                else if b == 125 || b == 93 {
                    depth -= 1
                    if depth == 0 { return start..<(i + 1) }
                }
            }
            return nil
        }
        var end = start
        while end < limit, bytes[end] != 44, bytes[end] != 125, bytes[end] != 93 { end += 1 }
        var trimmedEnd = end
        while trimmedEnd > start, [9, 10, 13, 32].contains(bytes[trimmedEnd - 1]) { trimmedEnd -= 1 }
        return trimmedEnd > start ? start..<trimmedEnd : nil
    }

    private func skipWhitespace(_ cursor: inout Int, _ bytes: [UInt8]) {
        while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
    }
}
