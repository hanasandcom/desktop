import Foundation

private final class NativeVMAccessRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Authenticated VM access and host-option calls. Mutations are never retried automatically.
struct NativeVMAccessClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maximumResponseBytes = 512 * 1024
    private static let redirectBlocker = NativeVMAccessRedirectBlocker()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }()

    private let baseURL: URL
    private let userID: String
    private let token: String
    private let organizationID: String?
    private let send: Sender

    init(
        apiBaseURL: URL,
        userID: String,
        token: String,
        organizationID: String? = nil,
        impersonationToken: String = "",
        impersonatingUserID: String = "",
        send: Sender? = nil
    ) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !bearer.isEmpty else { throw NativeVMAccessError.signInRequired }
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeVMAccessError.impersonationUnsupported
        }
        guard Self.validBase(apiBaseURL), user.count <= 200, bearer.count <= 4_096,
              user.range(of: #"^[A-Za-z0-9_.:@-]+$"#, options: .regularExpression) != nil,
              bearer.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil,
              organization == nil || organization!.range(of: #"^[A-Za-z0-9_.:@-]{1,200}$"#, options: .regularExpression) != nil else {
            throw NativeVMAccessError.invalidEndpoint
        }
        self.baseURL = apiBaseURL
        self.userID = user
        self.token = bearer
        self.organizationID = organization
        if let send { self.send = send }
        else { self.send = { request in try await Self.session.data(for: request) } }
    }

    func loadConnection(for rawName: String) async throws -> NativeVMConnection {
        let name = try Self.validatedName(rawName)
        let result = try await request(path: "vm/\(Self.pathSegment(name))/connection", method: "GET")
        guard let object = try Self.object(result.data),
              let vmName = object["vmName"] as? String,
              vmName.caseInsensitiveCompare(name) == .orderedSame,
              let ip = object["vmIp"] as? String, ip.count <= 253,
              let username = object["username"] as? String, !username.isEmpty, username.count <= 100,
              let rawCount = object["certificateCount"] as? NSNumber,
              String(cString: rawCount.objCType) != "c", (0...10_000).contains(rawCount.intValue) else {
            throw NativeVMAccessError.invalidResponse
        }
        let command: String?
        if let rawCommand = object["sshCommand"], !(rawCommand is NSNull) {
            guard let value = rawCommand as? String, value.count <= 4_096,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw NativeVMAccessError.invalidResponse
            }
            command = value.isEmpty ? nil : value
        } else { command = nil }
        return NativeVMConnection(vmName: name, ipAddress: ip, username: username,
                                  sshCommand: command, certificateCount: rawCount.intValue)
    }

    /// Reveals only the server-returned sudo password after the account password is supplied.
    /// The value is returned to the caller and is never logged or persisted by this client.
    func revealSudoPassword(for rawName: String, currentPassword: String) async throws -> String {
        let name = try Self.validatedName(rawName)
        guard !currentPassword.isEmpty, currentPassword.count <= 4_096,
              !currentPassword.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw NativeVMAccessError.invalidPassword
        }
        let body = try JSONSerialization.data(withJSONObject: ["currentPassword": currentPassword])
        let result = try await request(path: "vm/\(Self.pathSegment(name))/sudo-password", method: "POST", body: body, mutation: true)
        guard let object = try Self.object(result.data),
              let password = object["password"] as? String,
              !password.isEmpty, password.count <= 1_024,
              !password.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeVMAccessError.invalidResponse
        }
        return password
    }

    func updateFailover(for rawName: String, enabled: Bool) async throws -> NativeVMHostOptions {
        let name = try Self.validatedName(rawName)
        let body = try JSONSerialization.data(withJSONObject: ["failover_enabled": enabled])
        let result = try await request(path: "vm/\(Self.pathSegment(name))/host-features", method: "PUT", body: body, mutation: true)
        guard let object = try Self.object(result.data),
              let hostOptions = try Self.parseHostOptions(object),
              hostOptions.vmName.caseInsensitiveCompare(name) == .orderedSame,
              hostOptions.failoverEnabled == enabled else {
            throw NativeVMAccessError.uncertainOutcome
        }
        return hostOptions
    }

    func runFailover(for rawName: String, targetHost rawTargetHost: String, requestID: UUID) async throws -> NativeVMFailoverReceipt {
        let name = try Self.validatedName(rawName)
        let targetHost = rawTargetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetHost.count <= 200,
              targetHost.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$"#, options: .regularExpression) != nil else {
            throw NativeVMAccessError.invalidResponse
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "targetHost": targetHost,
            "requestId": requestID.uuidString.lowercased()
        ])
        let result = try await request(path: "vm/\(Self.pathSegment(name))/failover", method: "POST", body: body, mutation: true)
        guard result.status == 202 else { throw NativeVMAccessError.uncertainOutcome }
        guard let object = try Self.object(result.data),
              let rawVM = object["vm"] as? [String: Any],
              let hostOptions = try Self.parseHostOptions(rawVM),
              hostOptions.vmName.caseInsensitiveCompare(name) == .orderedSame,
              hostOptions.standbyHost == targetHost,
              hostOptions.failoverPremium, hostOptions.failoverEnabled,
              let message = object["message"] as? String, !message.isEmpty, message.count <= 2_000 else {
            throw NativeVMAccessError.uncertainOutcome
        }
        return NativeVMFailoverReceipt(hostOptions: hostOptions, message: message)
    }

    func loadFailoverCheckoutURL(for rawName: String) async throws -> URL {
        let name = try Self.validatedName(rawName)
        let body = try JSONSerialization.data(withJSONObject: ["vmName": name, "feature": "failover"])
        let result = try await request(path: "billing/container-checkout", method: "POST", body: body, mutation: true)
        guard let object = try Self.object(result.data), let rawURL = object["url"] as? String,
              let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "checkout.stripe.com", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil else {
            throw NativeVMAccessError.invalidResponse
        }
        return url
    }

    private func request(path: String, method: String, body: Data? = nil, mutation: Bool = false) async throws -> (data: Data, status: Int) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let prefix = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let expectedPath = "/" + [prefix, path].filter { !$0.isEmpty }.joined(separator: "/")
        components?.path = expectedPath
        guard let url = components?.url, url.path == expectedPath,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased() else { throw NativeVMAccessError.invalidEndpoint }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(userID, forHTTPHeaderField: "id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let organizationID, !organizationID.isEmpty { request.setValue(organizationID, forHTTPHeaderField: "x-organization-id") }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { if mutation { throw NativeVMAccessError.uncertainOutcome }; throw NativeVMAccessError.requestFailed(0) }
        guard data.count <= Self.maximumResponseBytes else { throw NativeVMAccessError.responseTooLarge }
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              response.url?.host?.lowercased() == baseURL.host?.lowercased(),
              response.url?.path == expectedPath else { throw NativeVMAccessError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if mutation && (http.statusCode == 408 || http.statusCode >= 500) { throw NativeVMAccessError.uncertainOutcome }
            if http.statusCode == 401 || http.statusCode == 403 { throw NativeVMAccessError.accessDenied }
            throw NativeVMAccessError.requestFailed(http.statusCode)
        }
        return (data, http.statusCode)
    }

    private static func parseHostOptions(_ object: [String: Any]) throws -> NativeVMHostOptions? {
        guard let name = object["name"] as? String,
              name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"#, options: .regularExpression) != nil,
              let premium = object["failover_premium"] as? Bool,
              let enabled = object["failover_enabled"] as? Bool else { return nil }
        func optionalHost(_ key: String) throws -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let host = value as? String, host.count <= 200,
                  !host.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw NativeVMAccessError.invalidResponse
            }
            return host.isEmpty ? nil : host
        }
        return NativeVMHostOptions(vmName: name, primaryHost: try optionalHost("primary_host"),
                                  standbyHost: try optionalHost("failover_host"),
                                  failoverPremium: premium, failoverEnabled: enabled)
    }

    private static func object(_ data: Data) throws -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw NativeVMAccessError.invalidResponse }
        return value as? [String: Any]
    }

    private static func validatedName(_ raw: String) throws -> String {
        guard raw.count <= 100,
              raw.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              raw != ".", raw != "..", raw.lowercased() != "root", raw.lowercased() != "nobody" else {
            throw NativeVMAccessError.invalidVMName
        }
        return raw
    }

    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? value
    }

    private static func validBase(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return false }
        return true
    }
}
