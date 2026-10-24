import Foundation

private final class NativeCDNFilePreviewRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NativeCDNFilePreviewClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    private let baseURL: URL
    private let userID: String
    private let token: String
    private let sender: Sender

    init(baseURL: URL, userID: String = "", token: String = "", sender: Sender? = nil) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw NativeCDNFilePreviewError.invalidBaseURL
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (user.isEmpty && credential.isEmpty) || (Self.validCredential(user, max: 128) && Self.validCredential(credential, max: 4096)) else {
            throw NativeCDNFilePreviewError.invalidCredentials
        }
        self.baseURL = baseURL
        self.userID = user
        self.token = credential
        self.sender = sender ?? Self.sendBounded
    }

    func load(id: String) async throws -> NativeCDNFilePreview {
        guard Self.validIdentifier(id) else { throw NativeCDNFilePreviewError.invalidIdentifier }
        let url = baseURL.appendingAPIPath("files/\(segment(id))")
        guard url.scheme?.lowercased() == "https", url.host == baseURL.host,
              url.user == nil, url.password == nil else { throw NativeCDNFilePreviewError.invalidBaseURL }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("image/*, video/*, application/octet-stream;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !userID.isEmpty {
            request.setValue("id=\(userID); access_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await sender(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host,
              response.url?.user == nil, response.url?.password == nil else { throw NativeCDNFilePreviewError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NativeCDNFilePreviewError.requestFailed(http.statusCode) }
        guard !data.isEmpty, data.count <= NativeCDNFilePreviewLimits.responseBytes else {
            throw data.count > NativeCDNFilePreviewLimits.responseBytes ? NativeCDNFilePreviewError.responseTooLarge : .invalidResponse
        }
        let mediaType = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        guard Self.acceptedTypes.contains(mediaType) else { throw NativeCDNFilePreviewError.invalidResponse }
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return NativeCDNFilePreview(id: id, fileName: Self.fileName(from: disposition, fallback: id), mediaType: mediaType,
                                    data: data, disposition: disposition)
    }

    private static let acceptedTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif",
        "video/mp4", "video/webm", "video/ogg", "application/octet-stream",
    ]

    private static func fileName(from disposition: String, fallback: String) -> String {
        let extended = disposition.range(of: "filename\\*=UTF-8''([^;]+)", options: [.regularExpression, .caseInsensitive])
            .map { String(disposition[$0]).replacingOccurrences(of: "(?i)^filename\\*=UTF-8''", with: "", options: .regularExpression) }
            .flatMap { $0.removingPercentEncoding }
        let plain = disposition.range(of: "filename=\"([^\"]+)\"", options: [.regularExpression, .caseInsensitive])
            .map { String(disposition[$0]).replacingOccurrences(of: "(?i)^filename=\"|\"$", with: "", options: .regularExpression) }
        let candidate = extended ?? plain ?? fallback
        let safe = URL(fileURLWithPath: candidate).lastPathComponent
        return safe.isEmpty || safe == "." || safe == ".." ? fallback : String(safe.prefix(180))
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= NativeCDNFilePreviewLimits.identifierBytes
            && value.range(of: "^[A-Za-z0-9._~-]{1,200}$", options: .regularExpression) != nil
    }

    private static func validCredential(_ value: String, max: Int) -> Bool {
        value.utf8.count <= max && value.range(of: "^[A-Za-z0-9._~-]{1,\(max)}$", options: .regularExpression) != nil
    }

    private static func sendBounded(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NativeCDNFilePreviewRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > NativeCDNFilePreviewLimits.responseBytes { throw NativeCDNFilePreviewError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            guard data.count < NativeCDNFilePreviewLimits.responseBytes else { throw NativeCDNFilePreviewError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
