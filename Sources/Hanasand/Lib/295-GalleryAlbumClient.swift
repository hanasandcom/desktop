import Foundation

struct GalleryAlbumClient {
    let baseURL: URL
    let userId: String
    let authToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let configured = settings.cdnBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: configured), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw GalleryAlbumClientError.invalidBaseURL
        }
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
        if let send { self.send = send }
    }

    func listAlbums() async throws -> [GalleryAlbum] {
        try await decode([GalleryAlbum].self, path: "albums")
    }

    func album(id: String, offset: Int = 0) async throws -> GalleryAlbumDetail {
        guard (0...1_000_000).contains(offset) else { throw GalleryAlbumClientError.invalidPage }
        let item = try await decode(GalleryAlbumDetail.self, path: "albums/\(segment(id))?limit=60&offset=\(offset)")
        guard item.id == id, ["owner", "viewer", "contributor"].contains(item.role),
              item.offset == offset, item.limit == 60, item.total >= 0 else { throw GalleryAlbumClientError.invalidResponse }
        return item
    }

    func createAlbum(name: String) async throws -> GalleryAlbum {
        let cleaned = try validName(name)
        let album = try await sendJSON(GalleryAlbum.self, path: "albums", method: "POST", body: GalleryAlbumNamePayload(name: cleaned))
        guard album.owner == userId, !album.isPublic else { throw GalleryAlbumClientError.unconfirmedMutation }
        return album
    }

    func renameAlbum(id: String, name: String) async throws -> GalleryAlbum {
        let cleaned = try validName(name)
        let album = try await sendJSON(GalleryAlbum.self, path: "albums/\(segment(id))", method: "PATCH", body: GalleryAlbumNamePayload(name: cleaned))
        guard album.id == id, album.owner == userId else { throw GalleryAlbumClientError.unconfirmedMutation }
        return album
    }

    func deleteAlbum(_ album: GalleryAlbumDetail) async throws {
        guard GalleryAlbumAccess.canManage(album, currentUserId: userId) else { throw GalleryAlbumClientError.ownerRequired }
        let receipt = try await sendJSON(GalleryAlbumMutationReceipt.self, path: "albums/\(segment(album.id))", method: "DELETE")
        guard receipt.deleted == album.id else { throw GalleryAlbumClientError.unconfirmedMutation }
    }

    func addItems(_ ids: [String], to album: GalleryAlbumDetail) async throws -> (added: Int, requested: Int) {
        guard GalleryAlbumAccess.canAddItems(album) else { throw GalleryAlbumClientError.contributorRequired }
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty, unique.count <= 500 else { throw GalleryAlbumClientError.invalidSelection }
        for id in unique { _ = try segment(id) }
        let receipt = try await sendJSON(GalleryAlbumMutationReceipt.self, path: "albums/\(segment(album.id))/items", method: "POST", body: GalleryAlbumItemsPayload(fileIds: unique))
        guard let added = receipt.added, let requested = receipt.requested,
              added >= 0, added <= unique.count, requested == unique.count else { throw GalleryAlbumClientError.unconfirmedMutation }
        return (added, requested)
    }

    func removeItem(_ item: GalleryAlbumItem, from album: GalleryAlbumDetail) async throws {
        guard GalleryAlbumAccess.canRemove(item, album: album, currentUserId: userId) else { throw GalleryAlbumClientError.removeOwnItemsOnly }
        let receipt = try await sendJSON(GalleryAlbumMutationReceipt.self, path: "albums/\(segment(album.id))/items/\(segment(item.id))", method: "DELETE")
        guard receipt.removed == item.id else { throw GalleryAlbumClientError.unconfirmedMutation }
    }

    func setMember(_ userId: String, role: String, in album: GalleryAlbumDetail) async throws {
        guard GalleryAlbumAccess.canManage(album, currentUserId: self.userId) else { throw GalleryAlbumClientError.ownerRequired }
        let member = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard member.range(of: "^[A-Za-z0-9._-]{3,80}$", options: .regularExpression) != nil,
              member != self.userId, ["viewer", "contributor"].contains(role) else { throw GalleryAlbumClientError.invalidMember }
        let receipt = try await sendJSON(GalleryAlbumMutationReceipt.self, path: "albums/\(segment(album.id))/members", method: "POST", body: GalleryAlbumMemberPayload(userId: member, role: role))
        guard receipt.userId == member, receipt.role == role else { throw GalleryAlbumClientError.unconfirmedMutation }
    }

    func removeMember(_ memberId: String, from album: GalleryAlbumDetail) async throws {
        guard GalleryAlbumAccess.canManage(album, currentUserId: userId) else { throw GalleryAlbumClientError.ownerRequired }
        let receipt = try await sendJSON(GalleryAlbumMutationReceipt.self, path: "albums/\(segment(album.id))/members/\(segment(memberId))", method: "DELETE")
        guard receipt.removed == memberId else { throw GalleryAlbumClientError.unconfirmedMutation }
    }

    func listLibrary(offset: Int = 0) async throws -> [GalleryLibraryItem] {
        guard (0...1_000_000).contains(offset) else { throw GalleryAlbumClientError.invalidPage }
        return try await decode([GalleryLibraryItem].self, path: "files/user/\(segment(userId))?limit=60&offset=\(offset)&search=&media=images")
    }

    func thumbnail(for id: String) async throws -> Data {
        let (data, response) = try await perform(path: "files/\(segment(id))?variant=thumbnail", method: "GET", accept: "image/*")
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GalleryAlbumClientError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0, "Photo unavailable")
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased() ?? ""
        guard ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif"].contains(String(mime)),
              !data.isEmpty, data.count <= 5 * 1024 * 1024 else { throw GalleryAlbumClientError.invalidImage }
        return data
    }

    func albumURL(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { throw GalleryAlbumClientError.invalidResponse }
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)"),
              url.scheme == "https", url.host == baseURL.host else { throw GalleryAlbumClientError.invalidBaseURL }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let (data, _) = try await perform(path: path, method: "GET")
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch { throw GalleryAlbumClientError.invalidResponse }
    }

    private func sendJSON<T: Decodable>(_ type: T.Type, path: String, method: String) async throws -> T {
        try await sendJSON(type, path: path, method: method, bodyData: nil)
    }

    private func sendJSON<T: Decodable, Body: Encodable>(_ type: T.Type, path: String, method: String, body: Body) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await sendJSON(type, path: path, method: method, bodyData: data)
    }

    private func sendJSON<T: Decodable>(_ type: T.Type, path: String, method: String, bodyData: Data?) async throws -> T {
        let (responseData, _) = try await perform(path: path, method: method, body: bodyData)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: responseData)
        } catch { throw GalleryAlbumClientError.invalidResponse }
    }

    private func perform(path: String, method: String, body: Data? = nil, accept: String = "application/json") async throws -> (Data, URLResponse) {
        let url = try albumURL(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(url.origin, forHTTPHeaderField: "Origin")
        request.setValue("id=\(userId); access_token=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw GalleryAlbumClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw GalleryAlbumClientError.requestFailed(http.statusCode, message ?? "Album request failed")
        }
        return (data, response)
    }

    private func validName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else {
            throw GalleryAlbumClientError.invalidName
        }
        return name
    }

    private func segment(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 128 else { throw GalleryAlbumClientError.invalidIdentifier }
        return value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

}

enum GalleryAlbumClientError: LocalizedError {
    case invalidBaseURL, signInRequired, invalidCredentials, impersonationUnsupported, invalidPage, invalidResponse
    case invalidName, invalidIdentifier, invalidSelection, invalidMember, invalidImage
    case ownerRequired, contributorRequired, removeOwnItemsOnly, unconfirmedMutation
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Configure a secure CDN URL before using Albums."
        case .signInRequired: return "Sign in to manage albums."
        case .invalidCredentials: return "The configured account or session token cannot be sent safely as a CDN cookie. Sign in again."
        case .impersonationUnsupported: return "Switch back to your own account to manage albums."
        case .invalidPage: return "Invalid album page."
        case .invalidResponse: return "The album service returned an unexpected response. Refresh before retrying."
        case .invalidName: return "Album names must be 1–120 characters on one line."
        case .invalidIdentifier: return "Choose a valid album, photo, or account."
        case .invalidSelection: return "Select between 1 and 500 photos."
        case .invalidMember: return "Enter another Hanasand account ID and choose Viewer or Contributor."
        case .invalidImage: return "The CDN returned an unsupported or oversized thumbnail."
        case .ownerRequired: return "Only the album owner can make this change."
        case .contributorRequired: return "This album is view only."
        case .removeOwnItemsOnly: return "Contributors can only remove items they added."
        case .unconfirmedMutation: return "The change could not be confirmed. Refresh before retrying."
        case .requestFailed(let status, let message): return "\(message) (HTTP \(status)). Refresh before retrying."
        }
    }
}

private extension URL {
    var origin: String { "\(scheme ?? "https")://\(host ?? "")" }
}
