import Foundation
import XCTest

@testable import Hanasand

final class NativePublicAlbumClientTests: XCTestCase {
    func testPublicPageUsesTokenAndFiltersWithoutCredentials() async throws {
        var captured: URLRequest?
        let client = try makeClient(pageSender: { request in
            captured = request
            return (Data(Self.pageJSON.utf8), self.response(for: request.url!))
        })

        let page = try await client.loadPage(token: Self.token, offset: 24, search: "fjord view", month: "2026-10")

        XCTAssertEqual(captured?.url?.path, "/api/albums/public/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "24")
        XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "24")
        XCTAssertEqual(query?.first(where: { $0.name == "search" })?.value, "fjord view")
        XCTAssertEqual(query?.first(where: { $0.name == "month" })?.value, "2026-10")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(page.name, "Public photos")
        XCTAssertEqual(page.items.first?.id, "photo-1")
        XCTAssertEqual(page.timeline.first?.photoCount, 8)
        XCTAssertNil(page.nextOffset, "The page at offset 24 contains the final item in the 25-item album.")
    }

    func testThumbnailUsesCDNImageEndpointAndThumbnailVariant() async throws {
        var captured: URLRequest?
        let client = try makeClient(fileSender: { request in
            captured = request
            return (Data([0x89, 0x50, 0x4e, 0x47]), self.response(for: request.url!, headers: [
                "Content-Type": "image/webp",
                "Content-Disposition": "inline; filename=\"photo.webp\"",
            ]))
        })

        let image = try await client.thumbnail(for: NativePublicAlbumItem(id: "photo-1", name: "Photo", type: "image/jpeg", uploadedAt: nil, photoTakenAt: nil, sizeBytes: 100))

        XCTAssertEqual(captured?.url?.path, "/api/files/photo-1")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "thumbnail")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(image.mediaType, "image/webp")
        XCTAssertEqual(image.fileName, "photo.webp")
    }

    func testRejectsInvalidTokenSearchAndMalformedAlbumRows() async throws {
        let client = try makeClient(pageSender: { request in
            (Data(Self.pageJSON.utf8), self.response(for: request.url!))
        })
        do {
            _ = try await client.loadPage(token: "bad")
            XCTFail("Invalid public tokens must be rejected before requesting.")
        } catch { XCTAssertEqual(error as? NativePublicAlbumError, .invalidToken) }
        do {
            _ = try await client.loadPage(token: Self.token, search: String(repeating: "x", count: NativePublicAlbumLimits.maxSearchBytes + 1))
            XCTFail("Search parameters must stay bounded.")
        } catch { XCTAssertEqual(error as? NativePublicAlbumError, .invalidSearch) }

        let malformed = try makeClient(pageSender: { request in
            (Data(#"{"id":"album-1","name":"Album","items":[{"id":"bad","name":"x","type":"text/html"}],"total":1,"limit":24,"offset":0,"timeline":[],"month":""}"#.utf8), self.response(for: request.url!))
        })
        do {
            _ = try await malformed.loadPage(token: Self.token)
            XCTFail("Unsupported public media types must be rejected.")
        } catch { XCTAssertEqual(error as? NativePublicAlbumError, .invalidResponse) }
    }

    func testRejectsInsecureOrCrossHostBaseURLs() {
        XCTAssertThrowsError(try NativePublicAlbumClient(apiBaseURL: URL(string: "http://cdn.hanasand.com/api")!)) {
            XCTAssertEqual($0 as? NativePublicAlbumError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try NativePublicAlbumClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!, fileBaseURL: URL(string: "https://other.test/api")!)) {
            XCTAssertEqual($0 as? NativePublicAlbumError, .invalidBaseURL)
        }
    }

    private static let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private static let pageJSON = #"{"id":"album-1","name":"Public photos","items":[{"id":"photo-1","name":"fjord.jpg","type":"image/jpeg","uploaded_at":"2026-10-24T10:00:00Z","photo_taken_at":"2026-10-20T10:00:00Z","size_bytes":100}],"total":25,"limit":24,"offset":24,"timeline":[{"month_key":"2026-10","photo_count":8}],"month":"2026-10"}"#

    private func makeClient(pageSender: NativePublicAlbumClient.Sender? = nil,
                            fileSender: NativeCDNFilePreviewClient.Sender? = nil) throws -> NativePublicAlbumClient {
        try NativePublicAlbumClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!, pageSender: pageSender, fileSender: fileSender)
    }

    private func response(for url: URL, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
