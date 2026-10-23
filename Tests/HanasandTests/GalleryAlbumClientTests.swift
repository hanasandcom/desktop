import Foundation
import XCTest
@testable import Hanasand

final class GalleryAlbumClientTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.cdnBaseURL = "https://cdn.hanasand.test/api"
        value.userID = "owner"
        value.authToken = "token_abc-123.jwt"
        return value
    }

    private func http(_ json: String, status: Int = 200, type: String = "application/json") -> (Data, URLResponse) {
        let url = URL(string: "https://cdn.hanasand.test/api/albums")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        return (Data(json.utf8), response)
    }

    func testAlbumContractDecodesSnakeCaseAndPreservesRoleAndPaging() async throws {
        var requests: [URLRequest] = []
        let client = try GalleryAlbumClient(settings: settings) { request in
            requests.append(request)
            return self.http("""
            {"id":"album/a","name":"Trip","owner":"owner","is_public":false,"role":"owner","items":[{"id":"file-1","name":"Beach","type":"image/jpeg","added_by":"owner"}],"total":1,"limit":60,"offset":0,"members":[{"user_id":"guest","role":"viewer"}]}
            """)
        }
        let album = try await client.album(id: "album/a")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://cdn.hanasand.test/api/albums/album%2Fa?limit=60&offset=0")
        XCTAssertEqual(album.items.first?.addedBy, "owner")
        XCTAssertEqual(album.members?.first?.userId, "guest")
        XCTAssertTrue(GalleryAlbumAccess.canManage(album, currentUserId: "owner"))
        XCTAssertTrue(GalleryAlbumAccess.canRemove(album.items[0], album: album, currentUserId: "owner"))
    }

    func testCreateAndAddUseExactCDNContractAndIsolatedCookieSession() async throws {
        var requests: [URLRequest] = []
        let client = try GalleryAlbumClient(settings: settings) { request in
            requests.append(request)
            if request.httpMethod == "POST", request.url?.path.hasSuffix("/albums") == true {
                return self.http(#"{"id":"new-id","name":"Private trip","owner":"owner","is_public":false,"photo_count":0}"#)
            }
            return self.http(#"{"added":1,"requested":2}"#)
        }
        let created = try await client.createAlbum(name: " Private trip ")
        let detail = GalleryAlbumDetail(id: created.id, name: created.name, owner: "owner", isPublic: false, role: "owner", items: [], total: 0, limit: 60, offset: 0, members: [])
        let receipt = try await client.addItems(["photo-2", "photo-1", "photo-2"], to: detail)
        XCTAssertEqual(receipt.added, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://cdn.hanasand.test/api/albums")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://cdn.hanasand.test/api/albums/new-id/items")
        XCTAssertEqual(String(data: requests[1].httpBody!, encoding: .utf8), "{\"fileIds\":[\"photo-1\",\"photo-2\"]}")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "id=owner; access_token=token_abc-123.jwt")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Origin"), "https://cdn.hanasand.test")
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testOwnerCanEnableAndDisablePublicLinkUsingOnlyConfirmedServiceToken() async throws {
        var requests: [URLRequest] = []
        let token = String(repeating: "a", count: 32)
        let client = try GalleryAlbumClient(settings: settings) { request in
            requests.append(request)
            if request.httpMethod == "PATCH", request.httpBody == Data(#"{"isPublic":true}"#.utf8) {
                return self.http(#"{"id":"album-1","name":"Trip","owner":"owner","is_public":true,"public_token":"\#(token)"}"#)
            }
            return self.http(#"{"id":"album-1","name":"Trip","owner":"owner","is_public":false,"public_token":null}"#)
        }
        let album = GalleryAlbumDetail(id: "album-1", name: "Trip", owner: "owner", isPublic: false, role: "owner", items: [], total: 0, limit: 60, offset: 0, members: [])

        let enabled = try await client.setPublicLink(true, for: album)
        XCTAssertEqual(enabled.shareURL?.absoluteString, "https://cdn.hanasand.test/shared/\(token)")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://cdn.hanasand.test/api/albums/album-1")
        XCTAssertEqual(requests[0].httpMethod, "PATCH")
        XCTAssertEqual(String(data: requests[0].httpBody ?? Data(), encoding: .utf8), #"{"isPublic":true}"#)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let disabled = try await client.setPublicLink(false, for: album)
        XCTAssertFalse(disabled.isPublic)
        XCTAssertNil(disabled.shareURL)
        XCTAssertEqual(String(data: requests[1].httpBody ?? Data(), encoding: .utf8), #"{"isPublic":false}"#)
    }

    func testPublicLinkRequiresOwnerAndRejectsUnexpectedOrUnsafeToken() async throws {
        let viewer = GalleryAlbumDetail(id: "album-1", name: "Trip", owner: "someone", isPublic: false, role: "viewer", items: [], total: 0, limit: 60, offset: 0, members: nil)
        let forbiddenClient = try GalleryAlbumClient(settings: settings) { _ in
            XCTFail("A viewer must not send a public-link mutation")
            return self.http(#"{}"#)
        }
        do {
            _ = try await forbiddenClient.setPublicLink(true, for: viewer)
            XCTFail("Expected owner-only guard")
        } catch GalleryAlbumClientError.ownerRequired {}

        let ownerAlbum = GalleryAlbumDetail(id: "album-1", name: "Trip", owner: "owner", isPublic: false, role: "owner", items: [], total: 0, limit: 60, offset: 0, members: [])
        let unsafeClient = try GalleryAlbumClient(settings: settings) { _ in
            self.http(#"{"id":"album-1","name":"Trip","owner":"owner","is_public":true,"public_token":"https://evil.example/leak"}"#)
        }
        do {
            _ = try await unsafeClient.setPublicLink(true, for: ownerAlbum)
            XCTFail("Expected unconfirmed mutation")
        } catch GalleryAlbumClientError.unconfirmedMutation {}

        XCTAssertThrowsError(try forbiddenClient.publicAlbumURL(token: "../" + String(repeating: "a", count: 29))) { error in
            guard case GalleryAlbumClientError.invalidPublicLink = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRedirectIsRejectedAndRedirectBodyCannotRevealPublicToken() async throws {
        let session = URLSession(configuration: .ephemeral)
        let sourceURL = URL(string: "https://cdn.hanasand.test/api/albums/album-1")!
        let destination = URL(string: "https://attacker.example/collect")!
        var redirectedRequest: URLRequest? = URLRequest(url: destination)
        let redirectResponse = HTTPURLResponse(url: sourceURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
        let blocker = GalleryAlbumRedirectBlocker()
        blocker.urlSession(session, task: session.dataTask(with: sourceURL), willPerformHTTPRedirection: redirectResponse, newRequest: URLRequest(url: destination)) {
            redirectedRequest = $0
        }
        XCTAssertNil(redirectedRequest, "URLSession must not follow an album API redirect to another origin")

        let client = try GalleryAlbumClient(settings: settings) { request in
            XCTAssertEqual(request.url?.host, "cdn.hanasand.test")
            let response = HTTPURLResponse(url: sourceURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            return (Data(#"{"id":"album-1","name":"Trip","owner":"owner","is_public":true,"public_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8), response)
        }
        let album = GalleryAlbumDetail(id: "album-1", name: "Trip", owner: "owner", isPublic: false, role: "owner", items: [], total: 0, limit: 60, offset: 0, members: [])
        do {
            _ = try await client.setPublicLink(true, for: album)
            XCTFail("A redirect response must not be decoded as an album share receipt")
        } catch GalleryAlbumClientError.requestFailed(let status, _) {
            XCTAssertEqual(status, 302)
        }
    }

    func testClientRejectsImpersonationAndContributorCannotDeleteAlbumOrOtherItems() throws {
        var impersonating = settings
        impersonating.impersonatingUserID = "someone-else"
        XCTAssertThrowsError(try GalleryAlbumClient(settings: impersonating))

        let contributorAlbum = GalleryAlbumDetail(id: "a", name: "Album", owner: "owner", isPublic: false, role: "contributor", items: [], total: 0, limit: 60, offset: 0, members: nil)
        let otherItem = GalleryAlbumItem(id: "f", name: "Photo", type: "image/jpeg", owner: "owner", addedBy: "another-user")
        XCTAssertFalse(GalleryAlbumAccess.canManage(contributorAlbum, currentUserId: "owner"))
        XCTAssertTrue(GalleryAlbumAccess.canAddItems(contributorAlbum))
        XCTAssertFalse(GalleryAlbumAccess.canRemove(otherItem, album: contributorAlbum, currentUserId: "owner"))

        let member = GalleryAlbumMember(userId: "someone", role: "viewer")
        XCTAssertEqual(member.id, "someone")
    }

    func testThumbnailRequiresPrivateImageResponseAndValidatesActualBytes() async throws {
        var request: URLRequest?
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            let response = HTTPURLResponse(url: next.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/webp", "Cache-Control": "private, no-store"] )!
            return (Data([1, 2, 3]), response)
        }
        let thumbnail = try await client.thumbnail(for: "private photo")
        XCTAssertEqual(thumbnail, Data([1, 2, 3]))
        XCTAssertEqual(request?.url?.absoluteString, "https://cdn.hanasand.test/api/files/private%20photo?variant=thumbnail")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "image/*")
        XCTAssertEqual(request?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cookie"), "id=owner; access_token=token_abc-123.jwt")
    }
}
