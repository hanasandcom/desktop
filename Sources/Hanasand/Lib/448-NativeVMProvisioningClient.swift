import Foundation

private final class NativeVMProvisioningRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NativeVMProvisioningClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    private struct Reply { let data: Data; let status: Int }
    private let apiBaseURL: URL
    private let identityBaseURL: URL
    private let userID: String
    private let token: String
    private let organizationID: String
    private let isImpersonating: Bool
    private let scope: String
    private let send: Sender
    private let now: () -> Date
    private static let maximumResponseBytes = 4 * 1024 * 1024

    init(apiBaseURL: URL, userID: String, token: String, organizationID: String = "personal",
         impersonationToken: String = "", impersonatingUserID: String = "", send: Sender? = nil,
         now: @escaping () -> Date = Date.init) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !bearer.isEmpty else { throw NativeVMProvisioningError.signInRequired }
        guard impersonationToken.isEmpty && impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeVMProvisioningError.impersonationUnsupported
        }
        guard Self.validBase(apiBaseURL), Self.validIdentifier(user), Self.validIdentifier(organization),
              bearer.range(of: #"^[A-Za-z0-9._~-]{1,4096}$"#, options: .regularExpression) != nil else {
            throw NativeVMProvisioningError.invalidEndpoint
        }
        var identity = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        if apiBaseURL.host?.lowercased() == "api.hanasand.com" { identity?.host = "identity.hanasand.com" }
        guard let identityURL = identity?.url, Self.validBase(identityURL) else { throw NativeVMProvisioningError.invalidEndpoint }
        self.apiBaseURL = apiBaseURL
        identityBaseURL = identityURL
        self.userID = user
        self.token = bearer
        self.organizationID = organization.isEmpty ? "personal" : organization
        isImpersonating = !impersonationToken.isEmpty || !impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        scope = apiBaseURL.absoluteString + "|" + identityURL.absoluteString + "|" + user + "|" + organization
        self.now = now
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: NativeVMProvisioningRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    /// Reads current ownership and organization membership; callers cannot reuse an old snapshot for a write.
    func loadCreationAuthorization() async throws -> NativeVMProvisioningAuthorization {
        guard !isImpersonating else { throw NativeVMProvisioningError.impersonationUnsupported }
        _ = try await request(base: apiBaseURL, path: "vms/\(Self.pathSegment(userID))", method: "GET")
        if organizationID != "personal" {
            let reply = try await request(base: identityBaseURL, path: "organizations", method: "GET")
            guard let envelope = Self.object(reply.data), let rows = envelope["organizations"] as? [[String: Any]], rows.count <= 10_000,
                  rows.contains(where: { row in
                      row["id"] as? String == organizationID && row["lifecycleStatus"] as? String == "active"
                          && ["owner", "admin"].contains((row["role"] as? String ?? "").lowercased())
                  }) else { throw NativeVMProvisioningError.accessDenied }
        }
        return NativeVMProvisioningAuthorization(scope: scope, capturedAt: now(), organizationID: organizationID)
    }

    func suggestSetup(prompt rawPrompt: String, os: String) async throws -> NativeVMSetupPlan {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.count >= 5, prompt.count <= 1_200, NativeVMProvisioningOptions.operatingSystems.contains(os) else {
            throw NativeVMProvisioningError.invalidInput("Describe a supported Ubuntu setup in 5–1,200 characters.")
        }
        _ = try await loadCreationAuthorization()
        let body = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "os": os])
        let reply = try await request(base: apiBaseURL, path: "vm/setup-plan", method: "POST", body: body, timeout: 30)
        do {
            let plan = try JSONDecoder().decode(NativeVMSetupPlan.self, from: reply.data)
            return try NativeVMProvisioningPolicy.validateSetupPlan(plan)
        } catch let error as NativeVMProvisioningError { throw error }
        catch { throw NativeVMProvisioningError.invalidResponse }
    }

    func create(_ rawInput: NativeVMCreateInput, authorization: NativeVMProvisioningAuthorization) async throws -> NativeVMProvisioningReceipt {
        let input = try NativeVMProvisioningPolicy.validated(rawInput)
        try validateScope(authorization)
        let fresh = try await loadCreationAuthorization()
        try validate(fresh)
        let scopedOrganization = organizationID == "personal" ? nil : organizationID
        guard input.organization_id == nil || input.organization_id == scopedOrganization else { throw NativeVMProvisioningError.wrongScope }
        var payload = input
        payload.organization_id = scopedOrganization
        let body = try JSONEncoder().encode(payload)
        let reply = try await request(base: apiBaseURL, path: "vm", method: "POST", body: body, timeout: 180, mutation: true)
        guard reply.status == 201 else { throw NativeVMProvisioningError.uncertainOutcome }
        return try Self.parseReceipt(reply.data, requestedName: input.name, organizationID: scopedOrganization)
    }

    /// Resume is allowed only after fresh VM and details reads establish empty details and current authority.
    func loadResumeAuthorization(for rawName: String) async throws -> NativeVMProvisioningAuthorization {
        let name = try Self.validatedVMName(rawName)
        guard !isImpersonating else { throw NativeVMProvisioningError.impersonationUnsupported }
        let vmReply = try await request(base: apiBaseURL, path: "vm/\(Self.pathSegment(name))", method: "GET")
        guard let vm = Self.firstObject(vmReply.data), vm["name"] as? String == name else { throw NativeVMProvisioningError.wrongScope }
        let vmOrganization = vm["organization_id"] as? String
        guard organizationID == "personal" ? (vmOrganization == nil || vmOrganization == "") : vmOrganization == organizationID else {
            throw NativeVMProvisioningError.wrongScope
        }
        guard vm["deleted_at"] == nil || vm["deleted_at"] is NSNull else { throw NativeVMProvisioningError.invalidInput("Restore this VM before resuming its setup.") }
        let details = try await request(base: apiBaseURL, path: "vm/details/\(Self.pathSegment(name))", method: "GET")
        guard let value = try? JSONSerialization.jsonObject(with: details.data, options: [.fragmentsAllowed]), value is NSNull || ((value as? [Any])?.isEmpty == true) else {
            throw NativeVMProvisioningError.invalidInput("This VM already has stored details and cannot be resumed through setup.")
        }
        let accessReply = try await request(base: identityBaseURL, path: "management/organizations?internalPages=1", method: "GET")
        guard let access = Self.object(accessReply.data),
              let allowed = access["allowed"] as? Bool, let canEdit = access["canEdit"] as? Bool,
              (vm["owner"] as? String == userID || allowed && canEdit) else {
            throw NativeVMProvisioningError.accessDenied
        }
        return NativeVMProvisioningAuthorization(scope: scope, capturedAt: now(), organizationID: organizationID)
    }

    func resume(_ rawInput: NativeVMCreateInput, authorization: NativeVMProvisioningAuthorization, confirmation: String) async throws -> NativeVMProvisioningReceipt {
        let input = try NativeVMProvisioningPolicy.validated(rawInput)
        try validateScope(authorization)
        guard confirmation == input.name else { throw NativeVMProvisioningError.invalidInput("Type the exact VM name to confirm resuming its setup.") }
        let fresh = try await loadResumeAuthorization(for: input.name)
        try validate(fresh)
        var payload = input
        payload.organization_id = organizationID == "personal" ? nil : organizationID
        let reply = try await request(base: apiBaseURL, path: "vm", method: "POST", body: try JSONEncoder().encode(payload), timeout: 180, mutation: true)
        guard reply.status == 201 else { throw NativeVMProvisioningError.uncertainOutcome }
        return try Self.parseReceipt(reply.data, requestedName: input.name, organizationID: payload.organization_id)
    }

    private func validate(_ authorization: NativeVMProvisioningAuthorization) throws {
        let age = now().timeIntervalSince(authorization.capturedAt)
        guard authorization.scope == scope, authorization.organizationID == organizationID, age >= -5, age <= 30 else {
            throw NativeVMProvisioningError.staleAuthorization
        }
    }

    private func validateScope(_ authorization: NativeVMProvisioningAuthorization) throws {
        guard authorization.scope == scope, authorization.organizationID == organizationID else {
            throw NativeVMProvisioningError.staleAuthorization
        }
    }

    private func request(base: URL, path: String, method: String, body: Data? = nil, timeout: TimeInterval = 20, mutation: Bool = false) async throws -> Reply {
        guard let url = Self.endpoint(base, path: path) else { throw NativeVMProvisioningError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if organizationID != "personal", base.host?.lowercased() == apiBaseURL.host?.lowercased() {
            request.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, rawResponse): (Data, URLResponse)
        do { (data, rawResponse) = try await send(request) }
        catch { throw mutation ? NativeVMProvisioningError.uncertainOutcome : NativeVMProvisioningError.requestFailed(0) }
        guard data.count <= Self.maximumResponseBytes else { throw NativeVMProvisioningError.responseTooLarge }
        guard let response = rawResponse as? HTTPURLResponse, response.url?.scheme == url.scheme,
              response.url?.host?.lowercased() == url.host?.lowercased(), response.url?.path == url.path else {
            throw NativeVMProvisioningError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if mutation && (response.statusCode == 408 || response.statusCode >= 500) {
                throw NativeVMProvisioningError.uncertainOutcome
            }
            throw NativeVMProvisioningError.requestFailed(response.statusCode)
        }
        return Reply(data: data, status: response.statusCode)
    }

    private static func parseReceipt(_ data: Data, requestedName: String, organizationID: String?) throws -> NativeVMProvisioningReceipt {
        guard let object = object(data), let name = object["name"] as? String, name == requestedName,
              (object["organization_id"] as? String) == organizationID else { throw NativeVMProvisioningError.uncertainOutcome }
        return NativeVMProvisioningReceipt(name: name, organizationID: organizationID, acceptedStatus: 201)
    }
    private static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private static func firstObject(_ data: Data) -> [String: Any]? {
        if let object = object(data) { return object }
        if let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], rows.count == 1 { return rows[0] }
        return nil
    }
    private static func validatedVMName(_ name: String) throws -> String {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"#, options: .regularExpression) != nil,
              name != ".", name != ".." else { throw NativeVMProvisioningError.invalidInput("Choose a valid existing VM name.") }
        return name
    }
    private static func validBase(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }
    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._:@-]{1,200}$"#, options: .regularExpression) != nil
    }
    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
    private static func endpoint(_ base: URL, path: String) -> URL? {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(pieces[0])
        guard !path.hasPrefix("/"), !path.contains("\\"), route.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [prefix, route].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = pieces.count > 1 ? String(pieces[1]) : nil
        guard let url = components.url, url.scheme == base.scheme, url.host == base.host else { return nil }
        return url
    }
}
