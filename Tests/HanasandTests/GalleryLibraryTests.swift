import Foundation
import XCTest
@testable import Hanasand

final class GalleryLibraryTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.cdnBaseURL = "https://cdn.hanasand.test/api"
        value.userID = "owner"
        value.authToken = "token_abc-123.jwt"
        return value
    }

    private func response(_ request: URLRequest, _ body: String, status: Int = 200, type: String = "application/json") -> (Data, URLResponse) {
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        return (Data(body.utf8), http)
    }

    func testAlbumListEmptyStateDoesNotHideRequestFailures() {
        XCTAssertTrue(GalleryAlbumListPresentation.shouldShowEmptyState(albumCount: 0, isLoading: false, error: ""))
        XCTAssertFalse(GalleryAlbumListPresentation.shouldShowEmptyState(albumCount: 0, isLoading: true, error: ""))
        XCTAssertFalse(GalleryAlbumListPresentation.shouldShowEmptyState(albumCount: 0, isLoading: false, error: "Network unavailable"))
        XCTAssertFalse(GalleryAlbumListPresentation.shouldShowEmptyState(albumCount: 2, isLoading: false, error: ""))
    }

    func testPartialAlbumAddExplainsSkippedPhotos() {
        XCTAssertEqual(
            GalleryAlbumAddFeedback.message(added: 2, requested: 5),
            "Added 2 of 5 selected photos. 3 skipped because they were already in the album or unavailable to this account."
        )
        XCTAssertEqual(GalleryAlbumAddFeedback.message(added: 3, requested: 3), "Added all 3 selected photos.")
    }

    func testSearchAndFavoritesUseAuthenticatedOwnerScopedPagedContract() async throws {
        var request: URLRequest?
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            return self.response(next, #"[{"id":"img-1","name":"Aurora","type":"image/jpeg","is_favorite":true}]"#)
        }

        let page = try await client.listLibraryPage(offset: 60, search: "  blue sky & stars  ", favorites: true)

        XCTAssertEqual(page.items.map(\.id), ["img-1"])
        XCTAssertEqual(page.items.first?.isFavorite, true)
        XCTAssertEqual(page.nextOffset, 61)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cookie"), "id=owner; access_token=token_abc-123.jwt")
        let query = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "60")
        XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "60")
        XCTAssertEqual(query?.first(where: { $0.name == "search" })?.value, "blue sky & stars")
        XCTAssertNil(query?.first(where: { $0.name == "media" }), "The website gallery includes non-image files too")
        XCTAssertEqual(query?.first(where: { $0.name == "favorites" })?.value, "true")
        XCTAssertTrue(request?.url?.path.hasSuffix("/files/user/owner") == true)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testImagesJourneyFiltersToImagesWhileWebsiteGalleryKeepsAllMedia() async throws {
        let modes: [(ImagesJourneyLibraryMode, String?)] = [
            (ImagesJourneyLibraryMode(nativeSection: nil), "images"),
            (ImagesJourneyLibraryMode(nativeSection: "gallery"), nil),
        ]

        for (mode, expectedMedia) in modes {
            var request: URLRequest?
            let client = try GalleryAlbumClient(settings: settings) { next in
                request = next
                return self.response(next, "[]")
            }

            _ = try await client.listLibraryPage(imagesOnly: mode.mediaFilterIsImageOnly)

            let media = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "media" })?.value
            XCTAssertEqual(media, expectedMedia)
        }
    }

    func testLibraryDecodesVideoAndOptionalUploadMetadata() async throws {
        let client = try GalleryAlbumClient(settings: settings) { request in
            self.response(request, #"[{"id":"video-1","name":"Clip.mp4","type":"video/mp4","uploaded_at":"2026-10-20T12:00:00Z","size_bytes":"2048"}]"#)
        }
        let page = try await client.listLibraryPage()
        XCTAssertEqual(page.items.first?.type, "video/mp4")
        XCTAssertEqual(page.items.first?.uploadedAt, "2026-10-20T12:00:00Z")
        XCTAssertEqual(page.items.first?.sizeBytes, 2048)
    }

    func testLibraryPagePaginationIsDerivedFromRawPageAndSearchIsBounded() async throws {
        var requestCount = 0
        let rows = (0..<60).map { #"{"id":"image-\#($0)","name":"Photo","type":"image/png","is_favorite":false}"# }.joined(separator: ",")
        let client = try GalleryAlbumClient(settings: settings) { request in
            requestCount += 1
            return self.response(request, "[\(rows)]")
        }

        let page = try await client.listLibraryPage(offset: 0)
        XCTAssertEqual(page.items.count, 60)
        XCTAssertEqual(page.nextOffset, 60)
        XCTAssertTrue(page.hasMore)
        do {
            _ = try await GalleryAlbumClient(settings: settings).listLibraryPage(search: String(repeating: "x", count: 201))
            XCTFail("Overlong search terms must be rejected")
        } catch GalleryAlbumClientError.invalidSearch {
            // No CDN request should be sent for invalid input.
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testAlbumPhotoPickerRequestsImagePagesFromTheCDN() async throws {
        var request: URLRequest?
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            return self.response(next, #"[{"id":"photo-1","name":"Beach","type":"image/jpeg"}]"#)
        }

        let page = try await client.listLibraryPage(offset: 60, imagesOnly: true)

        XCTAssertEqual(page.items.map(\.id), ["photo-1"])
        XCTAssertEqual(page.nextOffset, 61)
        XCTAssertFalse(page.hasMore)
        let query = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "media" })?.value, "images")
        XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "60")
    }

    func testAlbumCollectionPagePreservesSearchMetadataAndServerPagination() async throws {
        var request: URLRequest?
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            return self.response(next, #"{"id":"album/1","name":"Summer","owner":"owner","is_public":false,"role":"owner","items":[{"id":"photo-2","name":"Beach","type":"image/jpeg","is_favorite":true,"uploaded_at":"2026-10-01T12:00:00Z","size_bytes":"1024","added_by":"owner"}],"total":61,"limit":60,"offset":60,"members":[],"timeline":[{"month_key":"2026-10","photo_count":7}],"month":""}"#)
        }

        let page = try await client.listAlbumLibraryPage(albumId: "album/1", offset: 60, search: "  sea & sky ")

        XCTAssertEqual(request?.url?.absoluteString, "https://cdn.hanasand.test/api/albums/album%2F1?limit=60&offset=60&search=sea%20%26%20sky&media=images")
        let query = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "60")
        XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "60")
        XCTAssertEqual(query?.first(where: { $0.name == "search" })?.value, "sea & sky")
        XCTAssertEqual(query?.first(where: { $0.name == "media" })?.value, "images")
        XCTAssertEqual(page.items.first?.id, "photo-2")
        XCTAssertEqual(page.items.first?.isFavorite, true)
        XCTAssertEqual(page.items.first?.sizeBytes, 1024)
        XCTAssertEqual(page.items.first?.uploadedAt, "2026-10-01T12:00:00Z")
        XCTAssertEqual(page.nextOffset, 61)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.timeline, [GalleryAlbumMonth(monthKey: "2026-10", photoCount: 7)])
    }

    func testPrivateAlbumMonthFilterAndTimelineContract() async throws {
        var request: URLRequest?
        var requestCount = 0
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            requestCount += 1
            return self.response(next, #"{"id":"album/1","name":"Summer","owner":"owner","is_public":false,"role":"owner","items":[{"id":"photo-2","name":"Beach","type":"image/jpeg"}],"total":1,"limit":60,"offset":0,"members":[],"timeline":[{"month_key":"2026-10","photo_count":1}],"month":"2026-10"}"#)
        }

        let page = try await client.listAlbumLibraryPage(albumId: "album/1", month: "2026-10")

        XCTAssertEqual(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "month" })?.value, "2026-10")
        XCTAssertEqual(page.items.map(\.id), ["photo-2"])
        XCTAssertEqual(page.timeline, [GalleryAlbumMonth(monthKey: "2026-10", photoCount: 1)])

        do {
            _ = try await client.listAlbumLibraryPage(albumId: "album/1", month: "2026-13")
            XCTFail("Invalid month values must be rejected before a CDN request")
        } catch GalleryAlbumClientError.invalidMonth {
            // Invalid months never reach the authenticated album endpoint.
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testFavoriteMutationRequiresMatchingReceiptAndSendsExactPayload() async throws {
        var request: URLRequest?
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            return self.response(next, #"{"id":"img-9","favorite":true}"#)
        }

        let receipt = try await client.setFavorite(true, for: "img-9")

        XCTAssertEqual(receipt.id, "img-9")
        XCTAssertTrue(receipt.favorite)
        XCTAssertEqual(request?.httpMethod, "PATCH")
        XCTAssertEqual(request?.url?.path, "/api/files/img-9/favorite")
        XCTAssertEqual(String(data: request!.httpBody!, encoding: .utf8), #"{"favorite":true}"#)
        XCTAssertFalse(request!.httpShouldHandleCookies)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Origin"), "https://cdn.hanasand.test")

        let mismatched = try GalleryAlbumClient(settings: settings) { next in
            return self.response(next, #"{"id":"another-file","favorite":true}"#)
        }
        do {
            _ = try await mismatched.setFavorite(true, for: "img-9")
            XCTFail("Mismatched receipt must not be treated as a successful favorite update")
        } catch GalleryAlbumClientError.unconfirmedMutation {
            // The panel retains the old state and asks the user to refresh.
        }
    }

    func testOwnAccountGuardRejectsEitherImpersonationCredential() throws {
        var target = settings
        target.impersonatingUserID = "other-account"
        XCTAssertThrowsError(try GalleryAlbumClient(settings: target)) { error in
            guard case GalleryAlbumClientError.impersonationUnsupported = error else {
                return XCTFail("Expected impersonation guard")
            }
        }

        var token = settings
        token.impersonationToken = "impersonation-token"
        XCTAssertThrowsError(try GalleryAlbumClient(settings: token)) { error in
            guard case GalleryAlbumClientError.impersonationUnsupported = error else {
                return XCTFail("Expected impersonation guard")
            }
        }
    }

    func testOriginalImageUsesPrivateAuthenticatedCDNAndRejectsNonImageResponses() async throws {
        var request: URLRequest?
        let client = try GalleryAlbumClient(settings: settings) { next in
            request = next
            return self.response(next, "bytes", type: "image/avif; charset=binary")
        }
        let image = try await client.originalImage(for: "private image")
        XCTAssertEqual(image, Data("bytes".utf8))
        XCTAssertEqual(request?.url?.absoluteString, "https://cdn.hanasand.test/api/files/private%20image")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "image/*")

        let invalid = try GalleryAlbumClient(settings: settings) { next in
            return self.response(next, #"{"error":"not an image"}"#, type: "application/json")
        }
        do {
            _ = try await invalid.originalImage(for: "private image")
            XCTFail("A JSON response must not render as an image")
        } catch GalleryAlbumClientError.invalidImage {
            // User-visible preview retries are handled by the panel.
        }
    }
}
