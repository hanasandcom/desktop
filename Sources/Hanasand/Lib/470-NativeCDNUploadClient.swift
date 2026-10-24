import Foundation

private final class NativeCDNUploadRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum NativeCDNUploadSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NativeCDNUploadRedirectBlocker(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativePublicMediaImportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { return (Data(), response) }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > NativePublicMediaImportLimits.responseErrorBytes { throw NativePublicMediaImportError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < NativePublicMediaImportLimits.responseErrorBytes else {
                throw NativePublicMediaImportError.invalidResponse
            }
            data.append(byte)
        }
        return (data, response)
    }
}

struct NativeCDNUploadClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let authenticationHeaders: [String: String]?
    private let isGuest: Bool
    private let send: Sender

    init(cdnBaseURL: URL, userID: String, token: String, send: Sender? = nil) throws {
        guard let components = URLComponents(url: cdnBaseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw NativePublicMediaImportError.invalidBaseURL
        }

        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty && credential.isEmpty {
            authenticationHeaders = nil
            isGuest = true
        } else if let headers = NativePublicMediaImportClient.cdnUploadAuthenticationHeaders(userID: user, token: credential) {
            authenticationHeaders = headers
            isGuest = false
        } else {
            throw NativePublicMediaImportError.invalidCredentials
        }
        baseURL = cdnBaseURL
        self.send = send ?? NativeCDNUploadSession.send
    }

    func upload(fileURL: URL, name: String, description: String, path: String, type: String) async throws -> UploadedFileResponse {
        let values = try Self.validate(name: name, description: description, path: path, type: type)
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw NativePublicMediaImportError.emptyMedia
        }
        guard size <= NativePublicMediaImportLimits.maxBytes else { throw NativePublicMediaImportError.tooLarge }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw NativePublicMediaImportError.emptyMedia }
        guard data.count <= NativePublicMediaImportLimits.maxBytes else { throw NativePublicMediaImportError.tooLarge }

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.multipartBody(
            boundary: boundary,
            fileData: data,
            name: values.name,
            description: values.description,
            path: isGuest ? nil : values.path,
            type: values.type
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("files"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (header, value) in authenticationHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: header) }

        let (responseData, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host,
              response.url?.port == baseURL.port else {
            throw NativePublicMediaImportError.invalidResponse
        }
        if [301, 302, 303, 307, 308].contains(http.statusCode) {
            throw NativePublicMediaImportError.redirectBlocked
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NativePublicMediaImportError.uploadRecovery(status: http.statusCode)
        }
        guard responseData.count <= NativePublicMediaImportLimits.responseErrorBytes else {
            throw NativePublicMediaImportError.invalidResponse
        }
        guard let uploaded = try? JSONDecoder().decode(UploadedFileResponse.self, from: responseData),
              Self.validServerID(uploaded.id),
              uploaded.path.map(Self.validServerPath) ?? true else {
            throw NativePublicMediaImportError.invalidResponse
        }
        return uploaded
    }

    static func publicURL(cdnBaseURL: URL, uploaded: UploadedFileResponse, preferCustomPath: Bool) -> String? {
        guard validServerID(uploaded.id),
              var components = URLComponents(url: cdnBaseURL.appendingPathComponent("files"), resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        let safePath = preferCustomPath ? uploaded.path.flatMap { validServerPath($0) ? $0 : nil } : nil
        if let safePath {
            components.percentEncodedPath += "/path/" + safePath.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
            }.joined(separator: "/")
        } else {
            components.percentEncodedPath += "/" + uploaded.id
        }
        guard let url = components.url, url.host == host else { return nil }
        return url.absoluteString
    }

    static func multipartBody(boundary: String, fileData: Data, name: String, description: String, path: String?, type: String) -> Data {
        var body = Data()
        let fields: [(String, String)] = [("name", name), ("description", description), ("path", path ?? ""), ("type", type)]
            .filter { !$0.1.isEmpty }
        for (field, value) in fields {
            body.appendMultipartBoundary(boundary)
            body.appendUTF8("Content-Disposition: form-data; name=\"\(field)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        body.appendMultipartBoundary(boundary)
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\n")
        body.appendUTF8("Content-Type: \(type)\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n")
        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    private static func validate(name: String, description: String, path: String, type: String) throws -> (name: String, description: String, path: String, type: String) {
        guard !name.isEmpty, name.utf8.count <= 255, !containsRequestDelimiter(name) else {
            throw NativePublicMediaImportError.invalidUploadMetadata
        }
        guard description.utf8.count <= 1024 else { throw NativePublicMediaImportError.invalidUploadMetadata }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.utf8.count <= 180, !containsRequestDelimiter(path),
              path.isEmpty || (path != "." && path != ".."
                  && path.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil) else {
            throw NativePublicMediaImportError.invalidUploadMetadata
        }
        guard type.utf8.count <= 120,
              type.range(of: "^[\\w.+-]+/[\\w.+-]+(?:\\s*;\\s*[\\w=.+-]+)*$", options: .regularExpression) != nil else {
            throw NativePublicMediaImportError.invalidUploadType
        }
        return (name, description, path, type)
    }

    private static func containsRequestDelimiter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 || $0.value == 0x0A || $0.value == 0x0D }
    }

    private static func validServerID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
            && value != "." && value != ".."
    }

    private static func validServerPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 180, !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            let item = String(segment)
            return item != "." && item != ".."
                && item.range(of: "^[A-Za-z0-9._-]{1,180}$", options: .regularExpression) != nil
        }
    }
}
