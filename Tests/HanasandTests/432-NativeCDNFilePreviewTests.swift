import Foundation
import XCTest

@testable import Hanasand

final class NativeCDNFilePreviewTests: XCTestCase {
    func testLoadsRawCDNImageBytesFromAPIEndpointAndReadsSafeFilename() async throws {
        var captured: URLRequest?
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x00])
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            captured = request
            return (bytes, self.response(for: request.url!, headers: [
                "Content-Type": "image/png",
                "Content-Disposition": "inline; filename=\"screen.png\"; filename*=UTF-8''screen%20shot.png",
            ]))
        }

        let preview = try await client.load(id: "file-9")

        XCTAssertEqual(captured?.url?.path, "/api/files/file-9")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cookie"), "id=user-7; access_token=session-token")
        XCTAssertEqual(preview.data, bytes)
        XCTAssertEqual(preview.mediaType, "image/png")
        XCTAssertEqual(preview.fileName, "screen shot.png")
        XCTAssertTrue(preview.isImage)
    }

    func testAnonymousPublicAttachmentUsesRawResponseAndProvidesTextPreviewWhenKnown() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return (Data("# Public note".utf8), self.response(for: request.url!, headers: [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"readme.md\"",
            ]))
        }

        let preview = try await client.load(id: "public-file")

        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(preview.fileName, "readme.md")
        XCTAssertEqual(preview.textPreview, "# Public note")
        XCTAssertEqual(preview.disposition, "attachment; filename=\"readme.md\"")
    }

    func testRejectsUnsafeIDsUnsupportedMimeAndOversizedFiles() async throws {
        let client = try makeClient { request in
            (Data([1]), self.response(for: request.url!, headers: ["Content-Type": "text/html"]))
        }
        do {
            _ = try await client.load(id: "../private")
            XCTFail("Unsafe file IDs must be rejected before the network request.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidIdentifier) }
        do {
            _ = try await client.load(id: "file-1")
            XCTFail("The file API returns safe attachment types, not executable HTML.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidResponse) }

        let large = try makeClient { request in
            (Data(repeating: 0, count: NativeCDNFilePreviewLimits.responseBytes + 1), self.response(for: request.url!, headers: ["Content-Type": "image/png"]))
        }
        do {
            _ = try await large.load(id: "file-1")
            XCTFail("Responses over the preview size limit must fail safely.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .responseTooLarge) }
    }

    func testRejectsForeignOriginAndInsecureBase() async throws {
        let client = try makeClient { _ in
            (Data([1]), self.response(for: URL(string: "https://other.test/file")!, headers: ["Content-Type": "image/png"]))
        }
        do {
            _ = try await client.load(id: "file-1")
            XCTFail("Responses from another host must be rejected.")
        } catch { XCTAssertEqual(error as? NativeCDNFilePreviewError, .invalidResponse) }
        XCTAssertThrowsError(try NativeCDNFilePreviewClient(baseURL: URL(string: "http://cdn.hanasand.com/api")!)) {
            XCTAssertEqual($0 as? NativeCDNFilePreviewError, .invalidBaseURL)
        }
    }

    private func makeClient(userID: String = "", token: String = "", sender: @escaping NativeCDNFilePreviewClient.Sender) throws -> NativeCDNFilePreviewClient {
        try NativeCDNFilePreviewClient(baseURL: URL(string: "https://cdn.hanasand.com/api")!, userID: userID, token: token, sender: sender)
    }

    private func response(for url: URL, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
