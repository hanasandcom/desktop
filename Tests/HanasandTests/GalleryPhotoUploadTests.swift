import Foundation
import XCTest
@testable import Hanasand

final class GalleryPhotoUploadTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.cdnBaseURL = "https://cdn.hanasand.test/api"
        value.userID = "owner"
        value.authToken = "token_abc-123.jwt"
        return value
    }

    private func response(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, URLResponse) {
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), http)
    }

    func testUploadVerifiesSessionThenUsesMobileMultipartContractAndMapsOwnedImage() async throws {
        var requests: [URLRequest] = []
        let client = try GalleryPhotoUploadClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path.hasSuffix("/auth/session") == true {
                return self.response(request, #"{"id":"owner"}"#)
            }
            return self.response(request, #"{"id":"uploaded-1","owner":"owner"}"#)
        }
        let photo = GalleryPhotoUpload(name: "beach.heic", type: "image/heic", data: Data([0, 1, 2, 255]))

        let item = try await client.upload(photo)

        XCTAssertEqual(item, GalleryLibraryItem(id: "uploaded-1", name: "beach.heic", type: "image/heic", isFavorite: false))
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://cdn.hanasand.test/api/auth/session")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://cdn.hanasand.test/api/files")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "id=owner; access_token=token_abc-123.jwt")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Origin"), "https://cdn.hanasand.test")
        XCTAssertFalse(requests[1].httpShouldHandleCookies)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let contentType = try XCTUnwrap(requests[1].value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let multipart = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(multipart.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nbeach.heic"))
        XCTAssertTrue(multipart.contains("Content-Disposition: form-data; name=\"type\"\r\n\r\nimage/heic"))
        XCTAssertTrue(multipart.contains("name=\"file\"; filename=\"beach.heic\"\r\nContent-Type: image/heic"))
        XCTAssertTrue(multipart.contains(String(decoding: photo.data, as: UTF8.self)))
    }

    func testAccountMismatchPreventsPhotoBytesFromBeingSent() async throws {
        var requests: [URLRequest] = []
        let client = try GalleryPhotoUploadClient(settings: settings) { request in
            requests.append(request)
            return self.response(request, #"{"id":"another-account"}"#)
        }
        do {
            _ = try await client.upload(GalleryPhotoUpload(name: "a.jpg", type: "image/jpeg", data: Data([1])))
            XCTFail("Expected stale account session to stop upload")
        } catch GalleryPhotoUploadError.sessionMismatch {}
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testUnconfirmedOwnerAndInvalidImageNeverBecomeGalleryItems() async throws {
        let client = try GalleryPhotoUploadClient(settings: settings) { request in
            if request.url?.path.hasSuffix("/auth/session") == true { return self.response(request, #"{"id":"owner"}"#) }
            return self.response(request, #"{"id":"uploaded-1","owner":"someone-else"}"#)
        }
        do {
            _ = try await client.upload(GalleryPhotoUpload(name: "a.jpg", type: "image/jpeg", data: Data([1])))
            XCTFail("Expected ownership validation")
        } catch GalleryPhotoUploadError.ownershipUnconfirmed {}

        let invalidClient = try GalleryPhotoUploadClient(settings: settings) { _ in
            XCTFail("Invalid photo must be rejected before a request")
            throw GalleryAlbumClientError.invalidResponse
        }
        do {
            _ = try await invalidClient.upload(GalleryPhotoUpload(name: "bad\nname.jpg", type: "image/jpeg", data: Data([1])))
            XCTFail("Expected invalid filename")
        } catch GalleryPhotoUploadError.invalidName {}
        do {
            _ = try await invalidClient.upload(GalleryPhotoUpload(name: "a.jpg", type: "image/jpeg", data: Data()))
            XCTFail("Expected empty image rejection")
        } catch GalleryPhotoUploadError.invalidSize {}
        do {
            _ = try await invalidClient.upload(GalleryPhotoUpload(name: "a.svg", type: "image/svg+xml", data: Data([1])))
            XCTFail("Expected unsupported media type")
        } catch GalleryPhotoUploadError.unsupportedType {}
    }

    @MainActor
    func testBatchProgressStopsOnlyBetweenItemsAndRetainsRemainder() async {
        let items = [1, 2, 3]
        var uploaded: [Int] = []
        var stop = false
        let result = await GalleryPhotoUploadQueue.run(items, shouldStop: { stop }) { item in
            uploaded.append(item)
            stop = true
        }
        XCTAssertEqual(uploaded, [1])
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.pending, [2, 3])
        XCTAssertTrue(result.stopped)
        XCTAssertNil(result.error)
    }

    @MainActor
    func testBatchErrorRetainsFailedAndUnattemptedPhotosForRetry() async {
        let items = ["one", "two", "three"]
        var uploaded: [String] = []
        let result = await GalleryPhotoUploadQueue.run(items, shouldStop: { false }) { item in
            uploaded.append(item)
            if item == "two" { throw GalleryAlbumClientError.requestFailed(503, "Unavailable") }
        }
        XCTAssertEqual(uploaded, ["one", "two"])
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.pending, ["two", "three"])
        XCTAssertFalse(result.stopped)
        XCTAssertEqual(result.error, "Unavailable (HTTP 503). Refresh before retrying.")
    }

    func testSettingsRejectImpersonationAndMissingCredentials() {
        var impersonating = settings
        impersonating.impersonatingUserID = "other-account"
        XCTAssertThrowsError(try GalleryPhotoUploadClient(settings: impersonating))

        var signedOut = settings
        signedOut.authToken = ""
        XCTAssertThrowsError(try GalleryPhotoUploadClient(settings: signedOut))
    }
}
