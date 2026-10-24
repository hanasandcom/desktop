import Foundation

private final class NativePublicMediaImportRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum NativePublicMediaImportSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NativePublicMediaImportRedirectBlocker(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           [301, 302, 303, 307, 308].contains(http.statusCode) {
            throw NativePublicMediaImportError.redirectBlocked
        }
        if let http = response as? HTTPURLResponse,
           let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > NativePublicMediaImportLimits.maxBytes {
            throw NativePublicMediaImportError.tooLarge
        }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            guard data.count < NativePublicMediaImportLimits.maxBytes else {
                throw NativePublicMediaImportError.tooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

struct NativePublicMediaImportClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let websiteOrigin: URL
    private let userID: String
    private let token: String
    private let sender: Sender

    static func cdnUploadAuthenticationHeaders(userID: String, token: String) -> [String: String]? {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else { return nil }
        return ["Authorization": "Bearer \(credential)", "id": user]
    }

    init(websiteBaseURL: String, userID: String, token: String, sender: Sender? = nil) throws {
        guard let configured = URL(string: websiteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              configured.scheme?.lowercased() == "https", let host = configured.host, !host.isEmpty,
              configured.user == nil, configured.password == nil, configured.query == nil, configured.fragment == nil,
              configured.port == nil || configured.port == 443 else {
            throw NativePublicMediaImportError.invalidBaseURL
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !credential.isEmpty else { throw NativePublicMediaImportError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw NativePublicMediaImportError.invalidCredentials
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        guard let url = origin.url else { throw NativePublicMediaImportError.invalidBaseURL }
        websiteOrigin = url
        self.userID = user
        self.token = credential
        self.sender = sender ?? NativePublicMediaImportSession.send
    }

    func fetch(_ value: String) async throws -> NativePublicMediaImport {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let remote = URLComponents(string: raw),
              let scheme = remote.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = remote.host, !host.isEmpty, remote.user == nil, remote.password == nil,
              remote.fragment == nil else {
            throw NativePublicMediaImportError.invalidURL
        }
        guard raw.utf8.count <= NativePublicMediaImportLimits.maxURLBytes else {
            throw NativePublicMediaImportError.urlTooLong
        }
        guard remote.url != nil else { throw NativePublicMediaImportError.invalidURL }

        var components = URLComponents(url: websiteOrigin.appendingPathComponent("api/image"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "url", value: remote.string)]
        guard let url = components?.url, url.scheme == "https", url.host == websiteOrigin.host else {
            throw NativePublicMediaImportError.invalidBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("image/jpeg, image/png, image/gif, image/webp, image/avif, video/mp4, video/webm, video/ogg", forHTTPHeaderField: "Accept")
        request.setValue("id=\(userID); access_token=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await sender(request)
        } catch let error as NativePublicMediaImportError {
            throw error
        } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
            throw NativePublicMediaImportError.requestTimedOut
        } catch {
            throw NativePublicMediaImportError.requestFailed(0)
        }
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == websiteOrigin.host?.lowercased(),
              response.url?.port == nil || response.url?.port == 443 else {
            throw NativePublicMediaImportError.invalidResponse
        }
        guard !(300..<400).contains(http.statusCode) else { throw NativePublicMediaImportError.redirectBlocked }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NativePublicMediaImportError.signInRequired }
            if http.statusCode == 503 { throw NativePublicMediaImportError.serviceUnavailable }
            let message = Self.errorMessage(data)
            if http.statusCode == 413 { throw NativePublicMediaImportError.tooLarge }
            if let message {
                if message.localizedCaseInsensitiveContains("public") || message.localizedCaseInsensitiveContains("http or https") {
                    throw NativePublicMediaImportError.invalidURL
                }
                if message.localizedCaseInsensitiveContains("supported image or video") {
                    throw NativePublicMediaImportError.unsupportedMediaType
                }
                if message.localizedCaseInsensitiveContains("too many redirects") { throw NativePublicMediaImportError.redirectBlocked }
                if message.localizedCaseInsensitiveContains("empty") { throw NativePublicMediaImportError.emptyMedia }
                if message.localizedCaseInsensitiveContains("timed out") { throw NativePublicMediaImportError.requestTimedOut }
            }
            throw NativePublicMediaImportError.requestFailed(http.statusCode)
        }
        guard data.count <= NativePublicMediaImportLimits.maxBytes else { throw NativePublicMediaImportError.tooLarge }
        guard !data.isEmpty else { throw NativePublicMediaImportError.emptyMedia }
        let mediaType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        let name = Self.fileName(from: remote.url!)
        let imported = NativePublicMediaImport(data: data, fileName: name, mediaType: mediaType)
        try imported.validate()
        return imported
    }

    private static func fileName(from url: URL) -> String {
        let value = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        guard !value.isEmpty, value != "/", value.utf8.count <= NativePublicMediaImportLimits.maxFileNameBytes else { return "image.png" }
        return value
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard data.count <= NativePublicMediaImportLimits.responseErrorBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["error"] as? String
    }
}
