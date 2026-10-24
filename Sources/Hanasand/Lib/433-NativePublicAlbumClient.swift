import Foundation

private final class NativePublicAlbumRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum NativePublicAlbumSession {
    static func send(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NativePublicAlbumRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > limit {
            throw NativePublicAlbumError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(32 * 1024)
        for try await byte in bytes {
            guard data.count < limit else { throw NativePublicAlbumError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

struct NativePublicAlbumClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    private let apiBaseURL: URL
    private let fileBaseURL: URL
    private let pageSender: Sender
    private let fileSender: NativeCDNFilePreviewClient.Sender

    init(apiBaseURL: URL, fileBaseURL: URL? = nil, pageSender: Sender? = nil,
         fileSender: NativeCDNFilePreviewClient.Sender? = nil) throws {
        let files = fileBaseURL ?? apiBaseURL
        for base in [apiBaseURL, files] {
            guard base.scheme?.lowercased() == "https", base.host != nil,
                  base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
                throw NativePublicAlbumError.invalidBaseURL
            }
        }
        guard apiBaseURL.host?.lowercased() == files.host?.lowercased() else { throw NativePublicAlbumError.invalidBaseURL }
        self.apiBaseURL = apiBaseURL
        self.fileBaseURL = files
        self.pageSender = pageSender ?? { request in try await NativePublicAlbumSession.send(request, limit: NativePublicAlbumLimits.maxResponseBytes) }
        self.fileSender = fileSender ?? { request in
            try await NativePublicAlbumSession.send(request, limit: NativeCDNFilePreviewLimits.responseBytes)
        }
    }

    func loadPage(token: String, offset: Int = 0, search: String = "", month: String = "") async throws -> NativePublicAlbumPage {
        guard Self.validToken(token) else { throw NativePublicAlbumError.invalidToken }
        guard (0...1_000_000).contains(offset) else { throw NativePublicAlbumError.invalidPage }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.utf8.count <= NativePublicAlbumLimits.maxSearchBytes, !term.contains("\0") else {
            throw NativePublicAlbumError.invalidSearch
        }
        guard month.isEmpty || month.range(of: "^\\d{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil else {
            throw NativePublicAlbumError.invalidMonth
        }
        var components = URLComponents(url: apiBaseURL.appendingAPIPath("albums/public/\(token)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(NativePublicAlbumLimits.pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "month", value: month),
        ]
        guard let url = components?.url, url.scheme?.lowercased() == "https", url.host == apiBaseURL.host else {
            throw NativePublicAlbumError.invalidBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await pageSender(request)
        guard let http = response as? HTTPURLResponse, response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == apiBaseURL.host?.lowercased(), response.url?.user == nil,
              response.url?.password == nil else { throw NativePublicAlbumError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NativePublicAlbumError.requestFailed(http.statusCode) }
        guard data.count <= NativePublicAlbumLimits.maxResponseBytes else { throw NativePublicAlbumError.invalidResponse }
        let page: NativePublicAlbumPage
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            page = try decoder.decode(NativePublicAlbumPage.self, from: data)
        } catch { throw NativePublicAlbumError.invalidResponse }
        guard !page.id.isEmpty, page.name.utf8.count <= 512, page.total >= 0,
              page.offset == offset, page.limit == NativePublicAlbumLimits.pageSize,
              page.items.count <= NativePublicAlbumLimits.pageSize,
              page.timeline.count <= NativePublicAlbumLimits.maxTimelineRows,
              page.timeline.allSatisfy({ $0.monthKey.range(of: "^\\d{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil && $0.photoCount >= 0 }),
              page.items.allSatisfy({ $0.validateIfSafe() }) else { throw NativePublicAlbumError.invalidResponse }
        try page.items.forEach { try $0.validate() }
        return page
    }

    func thumbnail(for item: NativePublicAlbumItem) async throws -> NativeCDNFilePreview {
        try item.validate()
        guard item.type.hasPrefix("image/") else { throw NativePublicAlbumError.invalidResponse }
        let thumbnailSender: NativeCDNFilePreviewClient.Sender = { request in
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "variant", value: "thumbnail")]
            guard let url = components?.url else { throw NativePublicAlbumError.invalidResponse }
            var thumbnailRequest = request
            thumbnailRequest.url = url
            return try await fileSender(thumbnailRequest)
        }
        let client = try NativeCDNFilePreviewClient(baseURL: fileBaseURL, sender: thumbnailSender)
        return try await client.load(id: item.id)
    }

    func media(for item: NativePublicAlbumItem) async throws -> NativeCDNFilePreview {
        try item.validate()
        return try await NativeCDNFilePreviewClient(baseURL: fileBaseURL).load(id: item.id)
    }

    private static func validToken(_ value: String) -> Bool {
        value.utf8.count == 32 && value.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil
    }
}

private extension NativePublicAlbumItem {
    func validateIfSafe() -> Bool {
        (try? validate()) != nil
    }
}
