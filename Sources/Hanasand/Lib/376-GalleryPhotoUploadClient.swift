import Foundation

private enum GalleryPhotoUploadSession {
    static let shared = URLSession(configuration: .ephemeral, delegate: GalleryAlbumRedirectBlocker(), delegateQueue: nil)
}

struct GalleryPhotoUploadClient {
    static let maximumPhotoBytes = 50 * 1024 * 1024
    private static let supportedTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif"]

    let baseURL: URL
    let userId: String
    let authToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let configured = settings.cdnBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: configured), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw GalleryAlbumClientError.invalidBaseURL }
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw GalleryAlbumClientError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw GalleryAlbumClientError.invalidCredentials
        }
        guard settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.impersonationToken.isEmpty else { throw GalleryAlbumClientError.impersonationUnsupported }
        self.baseURL = url
        self.userId = user
        self.authToken = token
        self.send = send ?? { request in try await GalleryPhotoUploadSession.shared.data(for: request) }
    }

    func upload(_ photo: GalleryPhotoUpload) async throws -> GalleryLibraryItem {
        try validate(photo)
        let sessionData = try await perform(path: "auth/session", method: "GET", accept: "application/json")
        guard let session = try? JSONDecoder().decode(GalleryPhotoSession.self, from: sessionData), session.id == userId else {
            throw GalleryPhotoUploadError.sessionMismatch
        }

        let boundary = "Hanasand-\(UUID().uuidString)"
        let body = multipartBody(photo, boundary: boundary)
        let responseData = try await perform(
            path: "files",
            method: "POST",
            accept: "application/json",
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body
        )
        guard let receipt = try? JSONDecoder().decode(GalleryPhotoUploadReceipt.self, from: responseData),
              !receipt.id.isEmpty, receipt.owner == userId else {
            throw GalleryPhotoUploadError.ownershipUnconfirmed
        }
        return GalleryLibraryItem(id: receipt.id, name: photo.name, type: photo.type, isFavorite: false)
    }

    private func validate(_ photo: GalleryPhotoUpload) throws {
        guard !photo.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, photo.name.count <= 255,
              !photo.name.contains("\r"), !photo.name.contains("\n"), !photo.name.contains("\0") else {
            throw GalleryPhotoUploadError.invalidName
        }
        guard !photo.data.isEmpty, photo.data.count <= Self.maximumPhotoBytes else { throw GalleryPhotoUploadError.invalidSize }
        guard Self.supportedTypes.contains(photo.type.lowercased()) else { throw GalleryPhotoUploadError.unsupportedType }
    }

    private func multipartBody(_ photo: GalleryPhotoUpload, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("name", photo.name)
        field("type", photo.type)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(photo.name)\"\r\nContent-Type: \(photo.type)\r\n\r\n".utf8))
        body.append(photo.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func perform(path: String, method: String, accept: String, contentType: String = "application/json", body: Data? = nil) async throws -> Data {
        guard !path.hasPrefix("/"), !path.contains("..") else { throw GalleryAlbumClientError.invalidResponse }
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/\(path)"), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == baseURL.host?.lowercased() else { throw GalleryAlbumClientError.invalidBaseURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(url.origin, forHTTPHeaderField: "Origin")
        request.setValue("id=\(userId); access_token=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw GalleryAlbumClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw GalleryAlbumClientError.requestFailed(http.statusCode, message ?? "Photo upload failed")
        }
        return data
    }
}

private struct GalleryPhotoSession: Decodable { let id: String }
private struct GalleryPhotoUploadReceipt: Decodable { let id: String; let owner: String }

enum GalleryPhotoUploadError: LocalizedError {
    case invalidName, invalidSize, unsupportedType, sessionMismatch, ownershipUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Choose a photo with a valid file name."
        case .invalidSize: return "Photos must be between 1 byte and 50 MB."
        case .unsupportedType: return "Choose a JPEG, PNG, GIF, WebP, AVIF, or HEIC photo."
        case .sessionMismatch: return "Sign in again before uploading photos."
        case .ownershipUnconfirmed: return "Upload ownership could not be confirmed. Refresh your library before retrying."
        }
    }
}

private extension URL {
    var origin: String { "\(scheme ?? "https")://\(host ?? "")" }
}
