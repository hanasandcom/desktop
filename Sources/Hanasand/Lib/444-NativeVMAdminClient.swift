import Foundation

private final class NativeVMAdminRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Mock-injectable transport for the small set of VM administration mutations.
/// Every mutation requires a fresh authorization snapshot read by this client.
struct NativeVMAdminClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    static let maximumResponseBytes = 4 * 1024 * 1024
    static let authorizationMaximumAge: TimeInterval = 30

    private let apiBaseURL: URL
    private let identityBaseURL: URL
    private let userID: String
    private let token: String
    private let organizationID: String
    private let scope: String
    private let send: Sender
    private let now: () -> Date

    init(apiBaseURL: URL, userID: String, token: String, organizationID: String = "personal",
         impersonationToken: String = "", impersonatingUserID: String = "",
         send: Sender? = nil, now: @escaping () -> Date = Date.init) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !bearer.isEmpty else { throw NativeVMAdminError.signInRequired }
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeVMAdminError.impersonationUnsupported
        }
        guard Self.validBase(apiBaseURL),
              user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              bearer.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil,
              Self.validIdentifier(organization) else { throw NativeVMAdminError.invalidEndpoint }

        var identityComponents = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        if apiBaseURL.host?.lowercased() == "api.hanasand.com" {
            identityComponents?.host = "identity.hanasand.com"
        }
        guard let identity = identityComponents?.url, Self.validBase(identity) else { throw NativeVMAdminError.invalidEndpoint }
        self.apiBaseURL = apiBaseURL
        identityBaseURL = identity
        self.userID = user
        self.token = bearer
        self.organizationID = organization
        self.scope = UUID().uuidString + "|" + apiBaseURL.absoluteString + "|" + identity.absoluteString + "|" + user + "|" + organization
        self.now = now
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: NativeVMAdminRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    /// Reads both server authorities now. Call again immediately before a mutation.
    func loadAuthorization(for rawName: String) async throws -> NativeVMAdminAuthorization {
        let name = try Self.validatedName(rawName)
        async let vmData = request(base: apiBaseURL, path: "vm/\(Self.pathSegment(name))", method: "GET")
        async let accessData = request(base: identityBaseURL, path: "management/organizations?internalPages=1", method: "GET")
        let (vmResponse, accessResponse) = try await (vmData, accessData)
        let vm = try Self.parseVM(vmResponse.data)
        guard vm.name.caseInsensitiveCompare(name) == .orderedSame else { throw NativeVMAdminError.wrongScope }
        try validateOrganizationScope(vm)
        guard let object = try Self.object(accessResponse.data),
              let allowed = object["allowed"] as? Bool, let canEdit = object["canEdit"] as? Bool else {
            throw NativeVMAdminError.invalidResponse
        }
        return NativeVMAdminAuthorization(scope: scope, capturedAt: now(), vm: vm,
                                          access: NativeVMAdminAccess(allowed: allowed, canEdit: allowed && canEdit))
    }

    func assignOrganization(_ authorization: NativeVMAdminAuthorization, organizationID rawOrganizationID: String) async throws -> NativeVMAdminOrganizationReceipt {
        let vm = try authorize(authorization)
        let organization = try Self.validatedIdentifier(rawOrganizationID)
        guard vm.deletedAt == nil, vm.organizationID == nil, vm.canAssignOrganization,
              vm.owner == userID || (authorization.access.allowed && authorization.access.canEdit) else {
            throw NativeVMAdminError.accessDenied
        }
        let body = try JSONSerialization.data(withJSONObject: ["organizationId": organization])
        let response = try await request(base: apiBaseURL, path: "vm/\(Self.pathSegment(vm.name))/organization", method: "PUT", body: body, mutation: true)
        guard response.status == 200, let object = try Self.object(response.data),
              object["status"] as? Int == 200,
              let receipt = object["organization"] as? [String: Any],
              receipt["id"] as? String == organization,
              let name = receipt["name"] as? String, !name.isEmpty, name.count <= 200 else {
            throw NativeVMAdminError.uncertainOutcome
        }
        return NativeVMAdminOrganizationReceipt(id: organization, name: name)
    }

    func scheduleDeletion(_ authorization: NativeVMAdminAuthorization, confirmation: String) async throws -> NativeVMAdminDeletionReceipt {
        let vm = try authorizePlatform(authorization)
        guard vm.deletedAt == nil else { throw NativeVMAdminError.invalidInput }
        guard confirmation == vm.name else { throw NativeVMAdminError.invalidConfirmation }
        let body = try JSONSerialization.data(withJSONObject: ["confirmation": confirmation])
        let response = try await request(base: apiBaseURL, path: "vm/\(Self.pathSegment(vm.name))", method: "DELETE", body: body, mutation: true)
        return try deletionReceipt(response, matching: vm.name)
    }

    func restore(_ authorization: NativeVMAdminAuthorization) async throws -> NativeVMAdminDeletionReceipt {
        let vm = try authorizePlatform(authorization)
        guard vm.deletedAt != nil else { throw NativeVMAdminError.invalidInput }
        let response = try await request(base: apiBaseURL, path: "vm/\(Self.pathSegment(vm.name))/restore", method: "POST", mutation: true)
        return try deletionReceipt(response, matching: vm.name)
    }

    /// The supported stop-all mutation is POST /vms/stop. Never issue the legacy GET form.
    func stopAll(_ authorization: NativeVMAdminAuthorization) async throws -> NativeVMAdminStopReceipt {
        _ = try authorizePlatform(authorization)
        let response = try await request(base: apiBaseURL, path: "vms/stop", method: "POST", mutation: true)
        guard response.status == 200, let object = try Self.object(response.data),
              object["success"] as? Bool == true,
              let message = object["message"] as? String, !message.isEmpty, message.count <= 2_000,
              let rawNames = object["vms"] as? [String], rawNames.count <= 10_000 else {
            throw NativeVMAdminError.uncertainOutcome
        }
        let names = try rawNames.map(Self.validatedName)
        guard Set(names.map { $0.lowercased() }).count == names.count else { throw NativeVMAdminError.uncertainOutcome }
        return NativeVMAdminStopReceipt(message: message, vmNames: names)
    }

    private func authorize(_ authorization: NativeVMAdminAuthorization) throws -> NativeVMAdminRecord {
        let age = now().timeIntervalSince(authorization.capturedAt)
        guard authorization.scope == scope, age >= -5, age <= Self.authorizationMaximumAge else {
            throw NativeVMAdminError.staleAuthorization
        }
        try validateOrganizationScope(authorization.vm)
        return authorization.vm
    }

    private func authorizePlatform(_ authorization: NativeVMAdminAuthorization) throws -> NativeVMAdminRecord {
        let vm = try authorize(authorization)
        guard authorization.access.allowed, authorization.access.canEdit else { throw NativeVMAdminError.accessDenied }
        return vm
    }

    private func validateOrganizationScope(_ vm: NativeVMAdminRecord) throws {
        if organizationID != "personal", vm.organizationID != organizationID { throw NativeVMAdminError.wrongScope }
        if organizationID == "personal", let vmOrganization = vm.organizationID, !vmOrganization.isEmpty {
            throw NativeVMAdminError.wrongScope
        }
    }

    private func deletionReceipt(_ response: NativeVMAdminHTTPResponse, matching target: String) throws -> NativeVMAdminDeletionReceipt {
        guard response.status == 200, let body = try Self.object(response.data),
              let message = body["message"] as? String, !message.isEmpty, message.count <= 2_000,
              let rawVM = body["vm"] as? [String: Any] else { throw NativeVMAdminError.uncertainOutcome }
        let vm = try Self.parseVM(rawVM)
        guard vm.name.caseInsensitiveCompare(target) == .orderedSame else { throw NativeVMAdminError.uncertainOutcome }
        try validateOrganizationScope(vm)
        return NativeVMAdminDeletionReceipt(message: message, vm: vm)
    }

    private func request(base: URL, path: String, method: String, body: Data? = nil, mutation: Bool = false) async throws -> NativeVMAdminHTTPResponse {
        guard let url = Self.endpoint(base, path: path) else { throw NativeVMAdminError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: mutation ? 150 : 20)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if organizationID != "personal" { request.setValue(organizationID, forHTTPHeaderField: "x-organization-id") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let (data, rawResponse): (Data, URLResponse)
        do { (data, rawResponse) = try await send(request) }
        catch { throw mutation ? NativeVMAdminError.uncertainOutcome : NativeVMAdminError.requestFailed(0) }
        guard data.count <= Self.maximumResponseBytes else { throw NativeVMAdminError.responseTooLarge }
        guard let response = rawResponse as? HTTPURLResponse,
              let responseURL = response.url,
              responseURL.scheme?.lowercased() == url.scheme?.lowercased(),
              responseURL.host?.lowercased() == url.host?.lowercased(),
              responseURL.path == url.path,
              responseURL.query == url.query else { throw NativeVMAdminError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw mutation ? NativeVMAdminError.uncertainOutcome : NativeVMAdminError.requestFailed(response.statusCode)
        }
        return NativeVMAdminHTTPResponse(status: response.statusCode, data: data)
    }

    private static func object(_ data: Data) throws -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw NativeVMAdminError.invalidResponse }
        return value as? [String: Any]
    }

    private static func parseVM(_ data: Data) throws -> NativeVMAdminRecord {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw NativeVMAdminError.invalidResponse }
        if let rows = value as? [[String: Any]] {
            guard rows.count == 1, let row = rows.first else { throw NativeVMAdminError.invalidResponse }
            return try parseVM(row)
        }
        guard let object = value as? [String: Any] else { throw NativeVMAdminError.invalidResponse }
        return try parseVM(object)
    }

    private static func parseVM(_ value: [String: Any]) throws -> NativeVMAdminRecord {
        guard let rawName = value["name"] as? String else { throw NativeVMAdminError.invalidResponse }
        let name = try validatedName(rawName)
        guard let owner = value["owner"] as? String, owner.count <= 200, !owner.isEmpty,
              let assign = value["can_assign_organization"] as? Bool else { throw NativeVMAdminError.invalidResponse }
        let organization = try optionalText(value["organization_id"], maximum: 200)
        let deletedAt = try optionalText(value["deleted_at"], maximum: 100)
        return NativeVMAdminRecord(name: name, owner: owner, organizationID: organization, canAssignOrganization: assign, deletedAt: deletedAt)
    }

    private static func optionalText(_ value: Any?, maximum: Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String, text.count <= maximum else { throw NativeVMAdminError.invalidResponse }
        return text
    }

    private static func validBase(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return false }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        return scheme == "https" || (scheme == "http" && loopback)
    }

    private static func endpoint(_ base: URL, path: String) -> URL? {
        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        guard !path.hasPrefix("/"), !path.contains("\\"),
              route.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        components?.path = "/" + [basePath, String(pieces[0])].filter { !$0.isEmpty }.joined(separator: "/")
        components?.percentEncodedQuery = pieces.count == 2 ? String(pieces[1]) : nil
        guard let url = components?.url, url.scheme?.lowercased() == base.scheme?.lowercased(), url.host?.lowercased() == base.host?.lowercased() else { return nil }
        return url
    }

    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")) ?? ""
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil && value != "." && value != ".."
    }

    private static func validatedIdentifier(_ value: String) throws -> String {
        guard validIdentifier(value) else { throw NativeVMAdminError.invalidInput }
        return value
    }

    private static func validatedName(_ value: String) throws -> String {
        guard value.count <= 100,
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
              value != ".", value != "..", value.lowercased() != "root", value.lowercased() != "nobody" else {
            throw NativeVMAdminError.invalidInput
        }
        return value
    }
}

private struct NativeVMAdminHTTPResponse {
    let status: Int
    let data: Data
}
